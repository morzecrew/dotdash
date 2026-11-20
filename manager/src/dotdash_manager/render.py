"""Every machine's document, from the roster, the manager's state and the facts
at hand. Pure: it reads nothing and writes nothing."""

import hashlib

from . import rotate
from .roster import Network
from .state import public_key


def relay_line(f: dict, off: set[str] | frozenset[str] = frozenset(), split: bool = False) -> str:
    """The relay's line for a server's relays, as its relay-entry task prints
    it, with the paths its canaries find blocked (health.blocked) as off=, and
    split when they got REALITY through only with its hello split (health.splits)."""
    line = f"{f['entry_host']} {f['site']} {f['public_key']} {f['short_id']} {f['encryption']}"
    if "own_site" in f:
        line += f" own-site {f['own_site']['xhttp_path']}"
    if "kcp" in f:
        k = f["kcp"]
        line += f" kcp={k['port']},{k['header']},{k['seed']}" + (",quic" if k.get("open") == "quic" else "")
    if "hysteria2" in f:
        line += f" hy2={f['hysteria2']['port']}"
    if f.get("cdn_hosts"):
        line += " cdn=" + ",".join(f["cdn_hosts"])
    if f.get("cdn_only"):
        line += " cdn-only"
    if f.get("name"):
        line += f" name={f['name']}"
    if off:
        line += " off=" + ",".join(sorted(off))
    if split:
        line += " split"
    return line


def render(net: Network, state: dict, facts: dict, burnt: set[str] | frozenset[str] = frozenset(),
           off: dict[str, set[str]] | None = None, stands: dict[str, str] | None = None,
           split: set[str] | frozenset[str] = frozenset()) -> tuple[dict, list[str]]:
    """Every machine's document, by name, and what waits for facts not yet
    there. Burnt relays (health.judge) and spares held back (health.spares)
    are left out of the servers' relays and pools, so devices stop getting
    them; they and their canaries keep theirs. A spare standing in for a burnt
    relay (stands: spare, its burnt relay) takes that relay's place in the
    pools. A relay's blocked paths (health.blocked) go on its line as off=.
    The servers in split (health.splits) get hello_split, and those split at
    the last sync (state's split) and no longer, hello_split off; others none,
    as a server released before it refuses it. A relay in split goes on its
    line with split."""
    keys, ids = state["keys"], state["ids"]
    pbk = public_key(keys["reality_key"])
    known = [s for s in net.server if s.name in facts]
    # A server whose facts carry the manager's public key applied its document.
    ready = [s for s in known if facts[s.name].get("public_key") == pbk]
    waiting = [f"{s.name}: {'no facts yet' if s.id else 'not joined'}" for s in [*net.server, *net.relay] if s.name not in facts]
    waiting += [f"{s.name}: has not applied the keys yet" for s in known if s not in ready]
    vless = {kind: "\n".join(f"{ids[n]} {n}" for n in net.clients_of(kind)) for kind in ("server", "relay")}
    docs = {}

    off = off or {}
    relays = "\n".join(relay_line(facts[r.name], off.get(r.name, frozenset()), r.name in split)
                       for r in net.relay if r.name in facts and r.name not in burnt)
    # A pool naming a relay left out would name nothing: the server warns.
    hosts = lambda name: [facts[name]["entry_host"], *facts[name].get("cdn_hosts", [])]
    gone = {h for r in burnt if r in facts for h in hosts(r)}
    stands = stands or {}

    def members(ms: list[str]) -> list[str]:
        kept = [m for m in ms if m not in gone]
        for s, r in stands.items():
            if r in facts and s in facts and set(hosts(r)) & set(ms):
                kept += [h for h in hosts(s) if h not in kept]
        return kept

    pools = "\n".join(f"{p} {' '.join(kept)}" for p, ms in net.pools.items() if (kept := members(ms)))
    for s in net.server:
        others = [facts[o.name]["domain"] for o in known if o is not s]
        doc = {
            "parameters": {
                "servers": ",".join(["self", *others]),
                "subscription": str(net.subscription).lower(),
                "cdn_hosts": ",".join(s.cdn_hosts) or "none",
            },
            "secrets": {"vless_clients": vless["server"], **keys},
        }
        # Only when the roster says: a server released before direct refuses it.
        if net.direct is not None:
            doc["parameters"]["direct"] = str(net.direct).lower()
        unset = [name for name, value in (("relays", relays), ("pools", pools)) if not value]
        doc["parameters"].update({name: value for name, value in (("relays", relays), ("pools", pools)) if value})
        if unset:
            doc["unset"] = {"parameters": unset}
        # A REALITY key rotation (rotate): the second key beside reality_key,
        # and off again once it is done.
        if (two := rotate.second(state)) is not None:
            doc["parameters"]["reality_second_key"] = "true"
            doc["secrets"].update({f"{k}_second": v for k, v in two.items()})
        elif rotate.phase(state) == "done":
            doc["parameters"]["reality_second_key"] = "false"
        if s.name in split:
            doc["parameters"]["hello_split"] = "true"
        elif s.name in state.get("split", []):
            doc["parameters"]["hello_split"] = "false"
        docs[s.name] = doc

    lead = facts[ready[0].name] if ready else None
    if lead and len({facts[s.name]["https_port"] for s in ready}) > 1:
        waiting.append(f"servers differ in https_port: relays take {lead['https_port']}, {ready[0].name}'s")
    for r in net.relay:
        if not lead:
            waiting.append(f"{r.name}: waits for a server that applied the keys")
            continue
        docs[r.name] = {
            "parameters": {
                "dotdash_servers": ",".join(facts[s.name]["domain"] for s in ready),
                "dotdash_address": "none",
                "dotdash_port": str(lead["https_port"]),
                "dotdash_public_key": pbk,
                "ipv6": net.ipv6,
            },
            "secrets": {
                "vless_clients": vless["relay"],
                "dotdash_id": ids[f"relay-{r.name}"],
                "dotdash_encryption": lead["encryption"],
                "dotdash_short_id": keys["reality_short_id"],
            },
        }

    for c in net.canary:
        target = net.find(c.watches)
        f = facts.get(target.name)
        if not f or (target.kind == "server" and target not in ready):
            waiting.append(f"{c.name}: waits for {target.name}")
            continue
        if target.kind == "server":
            # Between rotate start and swap, the next key, which the canary proves first.
            checks = rotate.canary_key(state) or keys
            params = {"dotdash_server": f["domain"], "dotdash_address": f["domain"], "dotdash_port": str(f["https_port"]),
                      "dotdash_public_key": public_key(checks["reality_key"])}
            sec = {"dotdash_encryption": f["encryption"], "dotdash_short_id": checks["reality_short_id"],
                   "dotdash_xhttp_path": keys["xhttp_path"], "dotdash_kcp_seed": keys["kcp_seed"]}
            if "xhttp_reality_port" in f:
                params["dotdash_xhttp_reality_port"] = str(f["xhttp_reality_port"])
            if "hysteria2_port" in f:
                params["dotdash_hysteria2_port"] = str(f["hysteria2_port"])
        else:
            params = {"dotdash_server": f["site"], "dotdash_address": f["entry_host"], "dotdash_port": "443", "dotdash_public_key": f["public_key"]}
            sec = {"dotdash_encryption": f["encryption"], "dotdash_short_id": f["short_id"]}
            if "own_site" in f:
                sec["dotdash_xhttp_path"] = f["own_site"]["xhttp_path"]
            if "kcp" in f:
                sec["dotdash_kcp_seed"] = f["kcp"]["seed"]
            # A relay with Hysteria2 (its own site's): the canary's hysteria2
            # profile checks it as it checks a server's.
            if "hysteria2" in f:
                params["dotdash_hysteria2_port"] = str(f["hysteria2"]["port"])
        if "kcp" in f:
            params.update(dotdash_kcp_port=str(f["kcp"]["port"]), dotdash_kcp_header=f["kcp"]["header"], dotdash_kcp_open=f["kcp"].get("open", "none"))
        docs[c.name] = {"parameters": params, "secrets": {"dotdash_id": ids[f"canary-{c.name}"], **sec}}

    # direct = false keeps the servers' domains out of what devices hold, so a
    # client machine fetches through an own-site relay, as a phone does.
    own_site = [facts[r.name]["site"] for r in net.relay if "own_site" in facts.get(r.name, {})
                and r.name not in burnt and not facts[r.name].get("cdn_only")]
    for c in net.client:
        if not lead:
            waiting.append(f"{c.name}: waits for a server that applied the keys")
            continue
        token = hashlib.sha256(f"{keys['subscription_key']}:{ids[c.device]}".encode()).hexdigest()[:32]
        port = "" if lead["https_port"] == 443 else f":{lead['https_port']}"
        url = f"https://{lead['domain']}{port}/{token}"
        if net.direct is False:
            if not own_site:
                waiting.append(f"{c.name}: waits for an own-site relay: direct = false keeps the servers' URL out")
                continue
            url = f"https://{own_site[0]}/{token}"
        docs[c.name] = {"secrets": {"subscription_url": url, "proxy_password": state["passwords"][c.name]}}
    return docs, waiting
