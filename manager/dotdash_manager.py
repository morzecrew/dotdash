#!/usr/bin/env python3
"""dotdash-manager: a dotdash network from one roster, through morzer's desired state.

The roster (network.toml) names the servers, relays, canaries, clients and
devices. The manager makes the keys the servers share, reads the facts the
servers and relays publish (`morzer state facts`), renders every machine's
document and publishes the ones that changed (`morzer state publish`). It never
reaches a machine: each pulls its own document. Docs: pages/docs/manager.md.

Python 3.11+, standard library only; it runs the morzer and age-keygen binaries.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
import tomllib
import uuid
from pathlib import Path

KINDS = ("server", "relay", "canary", "client")
PRODUCTS = {"server": "dotdash", "relay": "dotdash-relay", "canary": "dotdash-canary", "client": "dotdash-client"}
IMAGES = {"server": "dotdash-server", "relay": "dotdash-relay", "canary": "dotdash-canary", "client": "dotdash-client"}
# A document lives 168 h (morzer's default): renew an unchanged one well before.
RENEW_AFTER = 3 * 86400
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
ID_RE = re.compile(r"^(inst|op)_[0-9A-Za-z]+$")
KEY_RE = re.compile(r"^[A-Za-z0-9+/]+=*$")
# Each secret the servers share, as its generator in bundles/server/secrets.schema.yaml makes it.
SHARED_KEYS = {
    "reality_key": lambda: b64url(secrets.token_bytes(32)),
    "vless_seed": lambda: secrets.token_hex(64),
    "reality_short_id": lambda: secrets.token_hex(8),
    "xhttp_path": lambda: secrets.token_hex(16),
    "kcp_seed": lambda: secrets.token_hex(16),
    "subscription_key": lambda: secrets.token_hex(32),
}


class Refused(Exception):
    pass


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


P25519 = 2**255 - 19


def x25519_public(private: bytes) -> bytes:
    """RFC 7748 X25519 of the base point: a REALITY key's public half, which
    tells a server that applied the manager's keys from one that has not."""
    k = bytearray(private)
    k[0] &= 248
    k[31] = (k[31] & 127) | 64
    n = int.from_bytes(k, "little")
    x2, z2, x3, z3, swap = 1, 0, 9, 1, 0
    for t in reversed(range(255)):
        bit = (n >> t) & 1
        if swap ^ bit:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b, c, d = x2 + z2, x2 - z2, x3 + z3, x3 - z3
        aa, bb, da, cb = a * a, b * b, d * a, c * b
        e = aa - bb
        x3, z3 = (da + cb) ** 2 % P25519, 9 * (da - cb) ** 2 % P25519
        x2, z2 = aa * bb % P25519, e * (aa + 121665 * e) % P25519
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P25519 - 2, P25519) % P25519).to_bytes(32, "little")


def public_key(reality_key: str) -> str:
    return b64url(x25519_public(base64.urlsafe_b64decode(reality_key + "=" * (-len(reality_key) % 4))))


# --- the roster and the manager's own state -------------------------------------


def load_roster(path: Path) -> dict:
    net = tomllib.loads(path.read_text())
    for field in ("target", "key", "identity", "authority"):
        if not isinstance(net.get(field), str) or not net[field]:
            raise Refused(f"{path}: set {field}")
    names = set()
    for kind in KINDS:
        net.setdefault(kind, [])
        for m in net[kind]:
            m["kind"] = kind
            name = m.get("name", "")
            if not NAME_RE.match(name) or name in names:
                raise Refused(f"{path}: [[{kind}]] name {name!r} is not 1 to 32 lowercase letters, digits and dashes, or is taken")
            names.add(name)
            if "id" in m and not ID_RE.match(m["id"]):
                raise Refused(f"{path}: {name}'s id is not an installation id (inst_…)")
            if "key" in m and not KEY_RE.match(m["key"]):
                raise Refused(f"{path}: {name}'s key is not a minisign public key (its single base64 line)")
    devices = net.setdefault("devices", [])
    for d in devices:
        if not NAME_RE.match(d) or d in names or d.startswith(("relay-", "canary-")):
            raise Refused(f"{path}: device {d!r} is not a free name of lowercase letters, digits and dashes (relay- and canary- are the manager's)")
        names.add(d)
    if net.get("ipv6", "allow") not in ("allow", "block"):
        raise Refused(f"{path}: ipv6 is allow or block")
    for c in net["canary"]:
        if c.get("watches") not in {m["name"] for m in net["server"] + net["relay"]}:
            raise Refused(f"{path}: canary {c['name']} watches {c.get('watches')!r}, which is no server or relay here")
    for c in net["client"]:
        if c.get("device") not in devices:
            raise Refused(f"{path}: client {c['name']} follows device {c.get('device')!r}, which devices does not list")
        if not net.get("subscription"):
            raise Refused(f"{path}: client machines follow a subscription: set subscription = true")
    for pool, members in net.get("pools", {}).items():
        if not NAME_RE.match(pool) or not all(isinstance(x, str) and re.match(r"^[A-Za-z0-9.:-]+$", x) for x in members):
            raise Refused(f"{path}: pool {pool!r} is not a name with a list of device names and hosts")
    return net


def load_state(path: Path, net: dict) -> dict:
    """Keys and ids the manager made, kept beside the roster: secret, so 0600."""
    state = json.loads(path.read_text()) if path.exists() else {}
    keys = state.setdefault("keys", {})
    for name, make in SHARED_KEYS.items():
        keys.setdefault(name, make())
    ids = state.setdefault("ids", {})
    for name in clients_of(net, "server"):
        ids.setdefault(name, str(uuid.uuid4()))
    passwords = state.setdefault("passwords", {})
    for c in net["client"]:
        passwords.setdefault(c["name"], secrets.token_urlsafe(18))
    state.setdefault("published", {})
    return state


def save_state(path: Path, state: dict) -> None:
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)


def write_morzer_roster(path: Path, net: dict) -> None:
    """morzer's roster (--expect): the machines that joined, with their keys."""
    lines = ["# Written by dotdash-manager from network.toml; edits here are lost.", "schema: 1", "installations:"]
    for kind in KINDS:
        for m in net[kind]:
            if "id" in m:
                lines += [f"  - product: {PRODUCTS[kind]}", f"    id: {m['id']}"] + ([f"    key: {m['key']}"] if "key" in m else [])
    path.write_text("\n".join(lines) + ("\n" if len(lines) > 3 else " []\n"))


# --- rendering ---------------------------------------------------------------------


def clients_of(net: dict, kind: str) -> list[str]:
    """Who a server's or a relay's vless_clients lets in: every device and canary,
    and on a server every relay, each through its own id."""
    names = list(net["devices"]) + [f"canary-{c['name']}" for c in net["canary"]]
    return names + ([f"relay-{r['name']}" for r in net["relay"]] if kind == "server" else [])


def relay_line(f: dict) -> str:
    """The relay's line for a server's relays, as its relay-entry task prints it."""
    line = f"{f['entry_host']} {f['site']} {f['public_key']} {f['short_id']} {f['encryption']}"
    if "own_site" in f:
        line += f" own-site {f['own_site']['xhttp_path']}"
    if "kcp" in f:
        k = f["kcp"]
        line += f" kcp={k['port']},{k['header']},{k['seed']}" + (",quic" if k.get("open") == "quic" else "")
    if f.get("cdn_hosts"):
        line += " cdn=" + ",".join(f["cdn_hosts"])
    return line


def render(net: dict, state: dict, facts: dict) -> tuple[dict, list[str]]:
    """Every machine's document, by name, from the roster, the manager's keys and
    the facts at hand; and what waits for facts not yet there."""
    keys, ids = state["keys"], state["ids"]
    pbk = public_key(keys["reality_key"])
    known = [s for s in net["server"] if s["name"] in facts]
    # A server whose facts carry the manager's public key applied its document.
    ready = [s for s in known if facts[s["name"]].get("public_key") == pbk]
    waiting = [f"{s['name']}: {'no facts yet' if 'id' in s else 'not joined'}" for s in net["server"] + net["relay"] if s["name"] not in facts]
    waiting += [f"{s['name']}: has not applied the keys yet" for s in known if s not in ready]
    vless = {kind: "\n".join(f"{ids[n]} {n}" for n in clients_of(net, kind)) for kind in ("server", "relay")}
    docs = {}

    relays = "\n".join(relay_line(facts[r["name"]]) for r in net["relay"] if r["name"] in facts)
    pools = "\n".join(f"{p} {' '.join(ms)}" for p, ms in net.get("pools", {}).items())
    for s in net["server"]:
        others = [facts[o["name"]]["domain"] for o in known if o is not s]
        doc = {
            "parameters": {
                "servers": ",".join(["self"] + others),
                "subscription": str(bool(net.get("subscription", False))).lower(),
                "cdn_hosts": ",".join(s.get("cdn_hosts", [])) or "none",
            },
            "secrets": {"vless_clients": vless["server"], **keys},
        }
        unset = [name for name, value in (("relays", relays), ("pools", pools)) if not value]
        doc["parameters"].update({name: value for name, value in (("relays", relays), ("pools", pools)) if value})
        if unset:
            doc["unset"] = {"parameters": unset}
        docs[s["name"]] = doc

    lead = facts[ready[0]["name"]] if ready else None
    if lead and len({facts[s["name"]]["https_port"] for s in ready}) > 1:
        waiting.append(f"servers differ in https_port: relays take {lead['https_port']}, {ready[0]['name']}'s")
    for r in net["relay"]:
        if not lead:
            waiting.append(f"{r['name']}: waits for a server that applied the keys")
            continue
        docs[r["name"]] = {
            "parameters": {
                "dotdash_servers": ",".join(facts[s["name"]]["domain"] for s in ready),
                "dotdash_address": "none",
                "dotdash_port": str(lead["https_port"]),
                "dotdash_public_key": pbk,
                "ipv6": net.get("ipv6", "allow"),
            },
            "secrets": {
                "vless_clients": vless["relay"],
                "dotdash_id": ids[f"relay-{r['name']}"],
                "dotdash_encryption": lead["encryption"],
                "dotdash_short_id": keys["reality_short_id"],
            },
        }

    for c in net["canary"]:
        target = next(m for m in net["server"] + net["relay"] if m["name"] == c["watches"])
        f = facts.get(target["name"])
        if not f or (target["kind"] == "server" and target not in ready):
            waiting.append(f"{c['name']}: waits for {target['name']}")
            continue
        if target["kind"] == "server":
            params = {"dotdash_server": f["domain"], "dotdash_address": f["domain"], "dotdash_port": str(f["https_port"]), "dotdash_public_key": pbk}
            sec = {"dotdash_encryption": f["encryption"], "dotdash_short_id": keys["reality_short_id"],
                   "dotdash_xhttp_path": keys["xhttp_path"], "dotdash_kcp_seed": keys["kcp_seed"]}
            if "xhttp_reality_port" in f:
                params["dotdash_xhttp_reality_port"] = str(f["xhttp_reality_port"])
        else:
            params = {"dotdash_server": f["site"], "dotdash_address": f["entry_host"], "dotdash_port": "443", "dotdash_public_key": f["public_key"]}
            sec = {"dotdash_encryption": f["encryption"], "dotdash_short_id": f["short_id"]}
            if "own_site" in f:
                sec["dotdash_xhttp_path"] = f["own_site"]["xhttp_path"]
            if "kcp" in f:
                sec["dotdash_kcp_seed"] = f["kcp"]["seed"]
        if "kcp" in f:
            params.update(dotdash_kcp_port=str(f["kcp"]["port"]), dotdash_kcp_header=f["kcp"]["header"], dotdash_kcp_open=f["kcp"].get("open", "none"))
        docs[c["name"]] = {"parameters": params, "secrets": {"dotdash_id": ids[f"canary-{c['name']}"], **sec}}

    for c in net["client"]:
        if not lead:
            waiting.append(f"{c['name']}: waits for a server that applied the keys")
            continue
        token = hashlib.sha256(f"{keys['subscription_key']}:{ids[c['device']]}".encode()).hexdigest()[:32]
        port = "" if lead["https_port"] == 443 else f":{lead['https_port']}"
        docs[c["name"]] = {"secrets": {"subscription_url": f"https://{lead['domain']}{port}/{token}",
                                       "proxy_password": state["passwords"][c["name"]]}}
    return docs, waiting


# --- morzer ------------------------------------------------------------------------


class Morzer:
    def __init__(self, net: dict, roster: Path, binary: str):
        self.net, self.binary = net, binary
        self.common = ["--target", net["target"], "--expect", str(roster)]
        if net.get("credentials"):
            self.common += ["--credentials-file", net["credentials"]]

    def run(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([self.binary, *args], input=stdin, capture_output=True, text=True, check=False)

    def facts(self, m: dict) -> dict | None:
        r = self.run("state", "facts", *self.common, "--product", PRODUCTS[m["kind"]], "--installation", m["id"],
                     "--identity", self.net["identity"], "--json")
        if r.returncode != 0:
            return None
        try:
            return json.loads(json.loads(r.stdout)["data"]["facts"])
        except (ValueError, KeyError, TypeError):
            print(f"{m['name']}: its facts are not the JSON its facts task prints; left out", file=sys.stderr)
            return None

    def publish(self, m: dict, doc: dict, dry_run: bool) -> subprocess.CompletedProcess:
        return self.run("state", "publish", *self.common, "--product", PRODUCTS[m["kind"]], "--installation", m["id"],
                        "--file", "-", "--key", self.net["key"], *(["--dry-run"] if dry_run else []), stdin=json.dumps(doc))


def paths(roster: Path) -> tuple[Path, Path]:
    return roster.with_name("dotdash-state.json"), roster.with_name("roster.yaml")


def gather(net: dict, mz: Morzer) -> dict:
    facts = {}
    for m in net["server"] + net["relay"]:
        if "id" in m and "key" in m and (f := mz.facts(m)) is not None:
            facts[m["name"]] = f
    return facts


def cmd_sync(args) -> int:
    net = load_roster(args.roster)
    state_path, roster_yaml = paths(args.roster)
    state = load_state(state_path, net)
    # Kept before anything goes out: a key published and then lost is a network to redo.
    save_state(state_path, state)
    write_morzer_roster(roster_yaml, net)
    mz = Morzer(net, roster_yaml, args.morzer)
    docs, waiting = render(net, state, gather(net, mz))
    failed = 0
    for kind in KINDS:
        for m in net[kind]:
            doc = docs.get(m["name"])
            if doc is None:
                continue
            if "id" not in m or "key" not in m:
                print(f"{m['name']}: not joined (no id and key in the roster); run join {m['name']}")
                continue
            digest = hashlib.sha256(json.dumps(doc, sort_keys=True).encode()).hexdigest()
            last = state["published"].get(m["id"], {})
            if last.get("digest") == digest and time.time() - last.get("at", 0) < RENEW_AFTER:
                print(f"{m['name']}: unchanged")
                continue
            r = mz.publish(m, doc, args.dry_run)
            if r.returncode != 0:
                failed += 1
                print(f"{m['name']}: publish failed: {(r.stderr or r.stdout).strip()}", file=sys.stderr)
                continue
            print(f"{m['name']}: {'would publish' if args.dry_run else 'published'}")
            if not args.dry_run:
                state["published"][m["id"]] = {"digest": digest, "at": int(time.time())}
                save_state(state_path, state)
    for w in waiting:
        print(f"waiting: {w}")
    return 1 if failed else 0


def cmd_status(args) -> int:
    net = load_roster(args.roster)
    _, roster_yaml = paths(args.roster)
    write_morzer_roster(roster_yaml, net)
    r = subprocess.run([args.morzer, "state", "ls", *Morzer(net, roster_yaml, args.morzer).common], check=False)
    for kind in KINDS:
        for m in net[kind]:
            if "id" not in m or "key" not in m:
                print(f"{m['name']} ({kind}): not joined; run join {m['name']}")
    return r.returncode


def cmd_join(args) -> int:
    """What to run on a new machine: init with the values it needs to come up,
    sync towards this authority, and how to add it to the roster."""
    net = load_roster(args.roster)
    m = next((x for kind in KINDS for x in net[kind] if x["name"] == args.name), None)
    if m is None:
        raise Refused(f"add {args.name} to {args.roster} first, as [[server]], [[relay]], [[canary]] or [[client]] with its name")
    state_path, roster_yaml = paths(args.roster)
    state = load_state(state_path, net)
    save_state(state_path, state)
    write_morzer_roster(roster_yaml, net)
    recipient = subprocess.run(["age-keygen", "-y", net["identity"]], capture_output=True, text=True, check=True).stdout.strip()
    kind = m["kind"]
    doc = None
    if kind != "server":
        docs, waiting = render(net, state, gather(net, Morzer(net, roster_yaml, args.morzer)))
        doc = docs.get(m["name"])
        if doc is None:
            raise Refused(f"{m['name']} can't come up yet: " + "; ".join(w for w in waiting if w.startswith(m["name"] + ":")))
    print(f"On the new {kind} machine (scripts/bootstrap.sh installs what it needs):\n")
    if kind == "relay":
        print("# A relay of its own domain: --domain <it> --profile own-site in place of site and entry_host.")
    init = [f"sudo morzer init --release oci://ghcr.io/morzecrew/{IMAGES[kind]}:stable", "--recovery-recipient age1…",
            f"--sync-target {net['target']} --sync-authority {net['authority']}"]
    if kind == "server":
        init.append("--domain <its domain>")
    elif kind == "relay":
        init.append("--set site=<a site next to it> --set entry_host=<its IP>")
    init += [f"--set {k}={v}" for k, v in (doc or {}).get("parameters", {}).items()]
    print(" \\\n  ".join(init))
    if kind == "server":
        print("sudo morzer secret set upstreams    # its ways out, one line each")
    for name, value in (doc or {}).get("secrets", {}).items():
        print(f"sudo morzer secret set {name} <<'END'\n{value}\nEND")
    # Sync before the first apply, so its facts go out with the first row.
    cred = ""
    if net.get("credentials"):
        print("sudo morzer secret set sync_target < <the target's credential document>")
        print("sudo morzer config set sync.credentials=sync_target")
        cred = " --credentials sync_target"
    print(f"sudo morzer config set sync.recipient={recipient} sync.enabled=true")
    print(f"sudo morzer backup target add {net['target']}{cred}")
    print("sudo morzer apply\nsudo morzer fleet publish")
    print("sudo morzer fleet publish --dry-run --json | jq -r '.data.row.installation_id, .data.row.signing_key'")
    print(f"\nThen give {m['name']} those two in {args.roster} (id = \"inst_…\", key = \"RW…\") and run sync.")
    if doc:
        print("\nThe secrets above are credentials: send them only to that machine.", file=sys.stderr)
    return 0


# --- the self-check ----------------------------------------------------------------


def selftest() -> int:
    # RFC 7748 §6.1, Alice.
    a = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    assert x25519_public(a).hex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    net = load_roster_text("""
target = "file:///tmp/t"
key = "a.key"
identity = "a.age"
authority = "RWQ"
subscription = true
devices = ["phone", "laptop"]
pools = { a = ["laptop", "203.0.113.5"] }
[[server]]
name = "a"
id = "inst_A"
key = "RWa"
[[server]]
name = "b"
id = "inst_B"
key = "RWb"
[[relay]]
name = "r1"
id = "inst_R"
key = "RWr"
[[canary]]
name = "c1"
watches = "r1"
[[client]]
name = "home"
device = "phone"
""")
    state = load_state(Path("/nonexistent"), net)
    pbk = public_key(state["keys"]["reality_key"])
    relay = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
             "kcp": {"port": 8447, "header": "dtls", "open": "quic", "seed": "K"}, "cdn_hosts": ["c.example.net"]}
    a = {"domain": "a.example.net", "https_port": 443, "public_key": pbk, "encryption": "mlkem…"}
    b = {"domain": "b.example.net", "https_port": 443, "public_key": "old", "encryption": "x"}

    docs, waiting = render(net, state, {"a": a, "b": b, "r1": relay})
    sa, sb = docs["a"], docs["b"]
    assert sa["parameters"]["servers"] == "self,b.example.net" and sb["parameters"]["servers"] == "self,a.example.net"
    assert sa["parameters"]["relays"] == "203.0.113.5 www.example.net P S E kcp=8447,dtls,K,quic cdn=c.example.net"
    assert sa["parameters"]["pools"] == "a laptop 203.0.113.5" and "unset" not in sa
    assert sa["secrets"]["reality_key"] == state["keys"]["reality_key"]
    names = [line.split()[1] for line in sa["secrets"]["vless_clients"].splitlines()]
    assert names == ["phone", "laptop", "canary-c1", "relay-r1"], names
    # Only a server that applied the keys carries the relays and the client.
    r1 = docs["r1"]
    assert r1["parameters"]["dotdash_servers"] == "a.example.net" and r1["parameters"]["dotdash_public_key"] == pbk
    assert r1["secrets"]["dotdash_id"] == state["ids"]["relay-r1"] and "relay-r1" not in r1["secrets"]["vless_clients"]
    assert "b: has not applied the keys yet" in waiting
    c1 = docs["c1"]
    assert c1["parameters"]["dotdash_address"] == "203.0.113.5" and c1["parameters"]["dotdash_kcp_open"] == "quic"
    assert c1["secrets"]["dotdash_kcp_seed"] == "K" and "dotdash_xhttp_path" not in c1["secrets"]
    token = hashlib.sha256(f"{state['keys']['subscription_key']}:{state['ids']['phone']}".encode()).hexdigest()[:32]
    assert docs["home"]["secrets"]["subscription_url"] == f"https://a.example.net/{token}"

    # Nothing applied yet: servers get their keys, everyone else waits.
    docs, waiting = render(net, state, {})
    assert set(docs) == {"a", "b"} and docs["a"]["unset"] == {"parameters": ["relays"]}
    assert docs["a"]["parameters"]["servers"] == "self"
    assert any(w.startswith("r1: waits") for w in waiting) and any(w.startswith("home: waits") for w in waiting)

    for bad in ('devices = ["relay-x"]', '[[canary]]\nname = "c"\nwatches = "nobody"', '[[server]]\nname = "Big"'):
        try:
            load_roster_text('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n' + bad)
        except Refused:
            continue
        raise AssertionError(f"took {bad!r}")
    print("selftest: ok")
    return 0


def load_roster_text(text: str) -> dict:
    import tempfile

    with tempfile.NamedTemporaryFile("w", suffix=".toml", delete=False) as f:
        f.write(text)
    try:
        return load_roster(Path(f.name))
    finally:
        os.unlink(f.name)


def main() -> int:
    p = argparse.ArgumentParser(prog="dotdash-manager", description="A dotdash network from one roster, through morzer's desired state.")
    p.add_argument("--roster", type=Path, default=Path("network.toml"), help="the roster (default: ./network.toml)")
    p.add_argument("--morzer", default="morzer", help="the morzer binary")
    p.add_argument("--selftest", action="store_true", help="check the rendering and exit")
    sub = p.add_subparsers(dest="command")
    s = sub.add_parser("sync", help="read facts, render every document, publish those that changed")
    s.add_argument("--dry-run", action="store_true", help="everything but the writes")
    sub.add_parser("status", help="what each machine applied and refused, and who has not joined")
    j = sub.add_parser("join", help="what to run on a new machine already named in the roster")
    j.add_argument("name")
    args = p.parse_args()
    if args.selftest:
        return selftest()
    if not args.command:
        p.print_help()
        return 2
    try:
        return {"sync": cmd_sync, "status": cmd_status, "join": cmd_join}[args.command](args)
    except Refused as e:
        print(f"dotdash-manager: {e}", file=sys.stderr)
        return 78


if __name__ == "__main__":
    sys.exit(main())
