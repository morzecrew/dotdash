"""Every machine's document, from the roster, the manager's state and the facts
at hand. Pure: it reads nothing and writes nothing."""

import hashlib

from .roster import Network
from .state import public_key


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


def render(net: Network, state: dict, facts: dict, burnt: set[str] | frozenset[str] = frozenset()) -> tuple[dict, list[str]]:
    """Every machine's document, by name, and what waits for facts not yet
    there. Burnt relays (health.judge) are left out of the servers' relays and
    pools, so devices stop getting them; they and their canaries keep theirs."""
    keys, ids = state["keys"], state["ids"]
    pbk = public_key(keys["reality_key"])
    known = [s for s in net.server if s.name in facts]
    # A server whose facts carry the manager's public key applied its document.
    ready = [s for s in known if facts[s.name].get("public_key") == pbk]
    waiting = [f"{s.name}: {'no facts yet' if s.id else 'not joined'}" for s in [*net.server, *net.relay] if s.name not in facts]
    waiting += [f"{s.name}: has not applied the keys yet" for s in known if s not in ready]
    vless = {kind: "\n".join(f"{ids[n]} {n}" for n in net.clients_of(kind)) for kind in ("server", "relay")}
    docs = {}

    live = [facts[r.name] for r in net.relay if r.name in facts and r.name not in burnt]
    relays = "\n".join(relay_line(f) for f in live)
    # A pool naming a relay left out would name nothing: the server warns.
    gone = {h for r in burnt if r in facts for h in [facts[r]["entry_host"], *facts[r].get("cdn_hosts", [])]}
    pools = "\n".join(f"{p} {' '.join(kept)}" for p, ms in net.pools.items() if (kept := [m for m in ms if m not in gone]))
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
        docs[c.name] = {"parameters": params, "secrets": {"dotdash_id": ids[f"canary-{c.name}"], **sec}}

    # direct = false keeps the servers' domains out of what devices hold, so a
    # client machine fetches through an own-site relay, as a phone does.
    own_site = [facts[r.name]["site"] for r in net.relay if "own_site" in facts.get(r.name, {}) and r.name not in burnt]
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
