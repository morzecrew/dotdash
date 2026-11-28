"""Every machine's document, from the roster, the manager's state and the facts
at hand. Pure: it reads nothing and writes nothing."""

import hashlib
import json
import uuid
from collections import Counter

from . import rotate
from .health import fronts
from .roster import Network
from .state import check_ids, public_key

# What a server's facts say that client-config takes for every server alike.
SHARED = ("https_port", "xhttp_reality_port", "kcp", "hysteria2_port")
# Every path a relay's off= can name but its CDNs': a burnt relay or a spare
# held back gets them all, so devices get nothing through it.
PATHS = ("reality", "xhttp", "mkcp", "hysteria2")


def relay_id(seed: str, name: str, nonce: str) -> str:
    """A relay's id on a group's servers, as their image derives it
    (xray-entrypoint relay-id): the version 4 UUID made of the first 16 bytes
    of sha256("<relay_seed>:relay:<name>:<nonce>")."""
    return str(uuid.UUID(bytes=hashlib.sha256(f"{seed}:relay:{name}:{nonce}".encode()).digest()[:16], version=4))


def relay_line(f: dict) -> str:
    """The relay's relay/1 line for a group's relays, as its relay-entry task
    prints it."""
    line = (f"relay/1 {f['name']} {f['nonce']} {f['entry_host']} {f['site']} {f['public_key']} {f['short_id']} "
            f"{f['encryption']}")
    if "own_site" in f:
        line += f" xhttp={f['own_site']['xhttp_path']}"
    if "kcp" in f:
        k = f["kcp"]
        line += f" kcp={k['port']},{k['header']},{k['seed']}" + (",quic" if k.get("open") == "quic" else "")
    if "hysteria2" in f:
        line += f" hy2={f['hysteria2']['port']}"
    if f.get("cdn_hosts"):
        line += " cdn=" + ",".join(f["cdn_hosts"])
    if f.get("cdn_path"):
        line += f" cdnpath={f['cdn_path']}"
    if f.get("origin_host"):
        line += f" origin={f['origin_host']}"
    if f.get("cdn_only"):
        line += " cdn-only"
    return line


def flags_line(f: dict, off: set[str] | frozenset[str], split: bool, standby: bool) -> str | None:
    """A relay's relay_flags line, by its name: standby when the roster says
    so, the paths its canaries find blocked (health.blocked) as off=, and split
    when they got REALITY through only with its hello split (health.splits).
    None without a flag."""
    words = (["standby"] if standby else []) + ([f"off={','.join(sorted(off))}"] if off else []) + (["split"] if split else [])
    return " ".join([f["name"], *words]) if words else None


def server_line(group: str, hosts: list[str], lead: dict, keys: dict, rid: str) -> str:
    """A group's server/1 line for a relay's servers, as its servers'
    relay-config prints it: the servers that applied its keys, the lead's port
    and encryption, its keys and the relay's id there; xr= where they serve
    XHTTP with REALITY."""
    line = (f"server/1 {group} {','.join(hosts)} {lead['https_port']} {public_key(keys['reality_key'])} "
            f"{keys['reality_short_id']} {lead['encryption']} {rid}")
    if "xhttp_reality_port" in lead:
        line += f" xr={lead['xhttp_reality_port']},{keys['xhttp_path']}"
    return line


def applied_keys(net: Network, state: dict, facts: dict, group: str) -> list:
    """A group's servers whose facts carry its public key: those that applied
    the manager's document, and so its keys."""
    pbk = public_key(state["keys"][group]["reality_key"])
    return [s for s in net.servers_of(group) if facts.get(s.name, {}).get("public_key") == pbk]


def relay_lines(net: Network, facts: dict) -> tuple[dict[str, str], list[str]]:
    """Each relay's relay/1 line, by its roster name, and what to say of those
    left out: a release from before them (its facts carry no nonce), or a name
    an earlier relay's facts carry, ignoring case, which the servers refuse."""
    lines, names, say = {}, {}, []
    for r in net.relay:
        f = facts.get(r.name)
        if f is None:
            continue
        if "nonce" not in f or "name" not in f:
            say.append(f"{r.name}: its release predates relay/1 lines (no nonce in its facts): update it; it is in no "
                       "group's relays until then")
        elif (first := names.setdefault(f["name"].lower(), r.name)) != r.name:
            say.append(f"{r.name}: its name, {f['name']}, is {first}'s too, which the servers refuse: rename one on the "
                       "relay (sudo morzer config set name=...); it is in no group's relays until then")
        else:
            lines[r.name] = relay_line(f)
    return lines, say


def kept_pools(net: Network, facts: dict, burnt: set[str] | frozenset[str],
               stands: dict[str, str]) -> tuple[dict[str, list[str]], list[str]]:
    """The pools as the servers get them, each with its members kept, and
    what to say: a burnt or held relay's hosts out, a spare standing in for
    one (stands: spare, its burnt relay) in its place. A pool left with no
    member is left out."""
    # A pool naming a relay left out would name nothing: the server warns.
    hosts = lambda name: [facts[name]["entry_host"], *fronts(facts[name])]
    # A host counts as a relay's only while no other relay's facts name it: a
    # burnt or held one claiming another's must not take it out of the pools,
    # nor bring its stand-in into that one's.
    named = Counter(h for r in net.relay if r.name in facts for h in set(hosts(r.name)))
    own = lambda name: [h for h in hosts(name) if named[h] == 1]
    say = [f"{h}: more than one relay's facts name it, so no burnt relay or spare moves it in the pools"
           for h in sorted(h for h, n in named.items() if n > 1)]
    gone = {h for r in burnt if r in facts for h in own(r)}

    def members(ms: list[str]) -> list[str]:
        kept = [m for m in ms if m not in gone]
        for s, r in stands.items():
            if r in facts and s in facts and set(own(r)) & set(ms):
                kept += [h for h in own(s) if h not in kept]
        return kept

    return {p: kept for p, ms in net.pools.items() if (kept := members(ms))}, say


def subscription_urls(net: Network, state: dict, facts: dict, device: str, lead: dict,
                      burnt: set[str] | frozenset[str], pools_kept: dict[str, list[str]]) -> list[str]:
    """A device's subscription URLs, as client-config prints them: its group's
    lead server's (the first that applied the keys), unless direct = false
    keeps it out, then the same through each own-site relay in its group's
    relays the device sees, in roster order. A device in a pool sees its
    pools' relays and those in none; one in none sees all. The token is
    subscription.sh's: sha256 of <subscription_key>:<id>, its first 32 hex
    characters."""
    group = net.group_of(device)
    keys = state["keys"][group]
    token = hashlib.sha256(f"{keys['subscription_key']}:{state['ids'][device]}".encode()).hexdigest()[:32]
    port = "" if lead["https_port"] == 443 else f":{lead['https_port']}"
    listed = {h for kept in pools_kept.values() for h in kept}
    mine = {h for kept in pools_kept.values() if device in kept for h in kept}
    lines = relay_lines(net, facts)[0]
    sites = [f["site"] for r in net.relay if r.name in lines and group in net.groups_of(r) and r.name not in burnt
             and "own_site" in (f := facts[r.name]) and not f.get("cdn_only")
             and (not mine or f["entry_host"] in mine or f["entry_host"] not in listed)]
    server = [] if net.direct is False else [f"https://{lead['domain']}{port}/{token}"]
    return server + [f"https://{site}/{token}" for site in sites]


def render(net: Network, state: dict, facts: dict, burnt: set[str] | frozenset[str] = frozenset(),
           off: dict[str, set[str]] | None = None, stands: dict[str, str] | None = None,
           split: set[str] | frozenset[str] = frozenset()) -> tuple[dict, list[str]]:
    """Every machine's document, by name, and what waits for facts not yet
    there. Each group's servers get its keys, its devices and canaries, and a
    relay/1 line for each relay that serves it; each relay a server/1 line
    for each group it serves, with its id there. Burnt relays (health.judge)
    and spares held back (health.spares) get every path off in the servers'
    relay_flags and leave the pools, so devices stop getting them, but stay in
    relays: a relay out of them is out of its id there, and its canaries could
    never get through again. They and their canaries keep their documents. A
    spare standing in for a burnt relay (stands: spare, its burnt relay) takes
    that relay's place in the pools. A relay's blocked paths (health.blocked)
    go in relay_flags as off=. The servers in split (health.splits) get
    hello_split, and those split at the last sync (state's split) and no
    longer, hello_split off; others none, as a server released before it
    refuses it. A relay in split gets split in relay_flags."""
    ids = state["ids"]
    check_ids(ids)
    off = off or {}
    ready = {g.name: applied_keys(net, state, facts, g.name) for g in net.group}
    waiting = [f"{s.name}: {'no facts yet' if s.id else 'not joined'}" for s in [*net.server, *net.relay] if s.name not in facts]
    waiting += [f"{s.name}: has not applied the keys yet" for s in net.server
                if s.name in facts and s not in ready[net.group_of(s)]]
    lines, more = relay_lines(net, facts)
    waiting += more
    pools_kept, more = kept_pools(net, facts, burnt, stands or {})
    waiting += more

    def vless(group: str) -> str:
        return "\n".join(f"{ids[n]} {n}" + (" desktop" if n in net.desktops else "") for n in net.clients_of(group))

    docs = {}
    for s in net.server:
        g = net.group_of(s)
        keys = state["keys"][g]
        others = [facts[o.name]["domain"] for o in net.servers_of(g) if o.name in facts and o is not s]
        listed = [r for r in net.relay if r.name in lines and g in net.groups_of(r)]
        relays = "\n".join(lines[r.name] for r in listed)
        flags = "\n".join(line for r in listed if (line := flags_line(
            facts[r.name], {*PATHS, *(f"cdn:{h}" for h in fronts(facts[r.name]))} if r.name in burnt
            else off.get(r.name, set()), r.name in split, r.standby)))
        # Another group's devices are no members here, and the server would
        # warn of each; a pool left with hosts alone keeps them from this
        # group's devices, as the roster says.
        theirs = set(net.devices) - set(net.clients_of(g))
        pools = "\n".join(f"{p} {' '.join(ms)}" for p, kept in pools_kept.items() if (ms := [m for m in kept if m not in theirs]))
        doc = {
            "parameters": {
                "servers": ",".join(["self", *others]),
                "name": g,
                "subscription": str(net.subscription).lower(),
                "cdn_hosts": ",".join(s.cdn_hosts) or "none",
            },
            "secrets": {"vless_clients": vless(g), **keys},
        }
        # Only when the roster says: a server released before direct refuses it.
        if net.direct is not None:
            doc["parameters"]["direct"] = str(net.direct).lower()
        if net.cdn_extra is not None:
            doc["parameters"]["cdn_extra"] = "\n".join(f"{h} {json.dumps(x)}" for h, x in net.cdn_extra.items()) or "none"
        texts = (("relays", relays), ("relay_flags", flags), ("pools", pools))
        doc["parameters"].update({name: value for name, value in texts if value})
        if unset := [name for name, value in texts if not value]:
            doc["unset"] = {"parameters": unset}
        # A REALITY key rotation (rotate): the second key beside reality_key,
        # and off again once it is done.
        if (two := rotate.second(state, g)) is not None:
            doc["parameters"]["reality_second_key"] = "true"
            doc["secrets"].update({f"{k}_second": v for k, v in two.items()})
        elif rotate.phase(state) == "done":
            doc["parameters"]["reality_second_key"] = "false"
            # The retired key out of the server's secret store, and so out of
            # its backups from then on, not only unused.
            doc.setdefault("unset", {})["secrets"] = [f"{k}_second" for k in rotate.KEYS]
        if s.name in split:
            doc["parameters"]["hello_split"] = "true"
        elif s.name in state.get("split", []):
            doc["parameters"]["hello_split"] = "false"
        docs[s.name] = doc

    # client-config gives every server in servers its own server's ports, mKCP
    # header and opener and profiles (each present or not): where those
    # differ, its subscriptions carry dead links to the others.
    for g, rs in ready.items():
        differ = [k for k in SHARED if len({json.dumps(facts[s.name].get(k), sort_keys=True) for s in rs}) > 1]
        if differ:
            waiting.append(f"{g}'s servers differ in {', '.join(differ)}: each server's links name the others with its "
                           "own, so some are dead; give every server the same profiles and ports"
                           + (f"; relays take {facts[rs[0].name]['https_port']}, {rs[0].name}'s"
                              if "https_port" in differ else ""))
    for r in net.relay:
        # Its line, with its name and nonce, are in its facts: without them
        # it has no id on any group (waiting says why).
        if r.name not in lines:
            continue
        f, servers, hold = facts[r.name], [], False
        for g in net.groups_of(r):
            if ready[g]:
                keys = state["keys"][g]
                servers.append(server_line(g, [facts[s.name]["domain"] for s in ready[g]], facts[ready[g][0].name], keys,
                                           relay_id(keys["relay_seed"], f["name"], f["nonce"])))
            elif any(s.name in facts for s in net.servers_of(g)):
                # Its servers are changing keys (a rotation's swap, a server
                # joined on its own): a document without its line would drop
                # its devices from this relay until the next sync.
                hold = True
                waiting.append(f"{r.name}: waits for {g}'s servers to apply its keys")
            else:
                waiting.append(f"{r.name}: {g} has no server with facts yet")
        # via: the other relays' relay/1 lines.
        missing = [v for v in r.via if v not in lines]
        siteless = [v for v in r.via if r.via_link == "xhttp" and v in lines and "own_site" not in facts[v]]
        if missing:
            waiting.append(f"{r.name}: goes via {', '.join(missing)}, which has no relay/1 line in its facts yet")
        if siteless:
            waiting.append(f"{r.name}: goes via {', '.join(siteless)} by XHTTP, which needs their own site")
        if hold or missing or siteless or not servers:
            continue
        doc = docs[r.name] = {
            "parameters": {"ipv6": net.ipv6, "server_link": r.server_link, "via_link": r.via_link,
                           "via_fingerprint": r.via_fingerprint},
            "secrets": {"servers": "\n".join(servers)},
        }
        if r.via:
            doc["secrets"]["via"] = "\n".join(lines[v] for v in r.via)
        else:
            doc["unset"] = {"secrets": ["via"]}
        if r.tunnel_group:
            doc["parameters"]["tunnel_group"] = r.tunnel_group
        else:
            doc.setdefault("unset", {})["parameters"] = ["tunnel_group"]

    for c in net.canary:
        target = net.find(c.watches)
        f = facts.get(target.name)
        group = net.group_of(c)
        if not f or (target.kind == "server" and target not in ready[group]):
            waiting.append(f"{c.name}: waits for {target.name}")
            continue
        keys = state["keys"][group]
        if target.kind == "server":
            # Between rotate start and swap, the next key, which the canary proves first.
            checks = rotate.canary_key(state, group) or keys
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
        # A relay's CDNs, each checked as devices' links through it go, on its
        # CDN path: its cdn_hosts and its door's (origin_host), none on a server.
        # Not one the roster gives a cdn_extra, whose settings the canary
        # doesn't carry. Only to a release that checks them, whose facts say
        # cdn, or one with no facts yet: an earlier one refuses the whole
        # document over them.
        path, extra = f.get("cdn_path"), net.cdn_extra or {}
        cdn = {"dotdash_cdn_hosts": f.get("cdn_hosts", []) if path else [],
               "dotdash_origin_host": [o for o in f.get("origin_host", "").split(",") if o] if path else []}
        if skipped := [h for hs in cdn.values() for h in hs if h.split("/")[0] in extra]:
            waiting.append(f"{c.name}: checks none of {target.name}'s CDNs with a cdn_extra in the roster "
                           f"({', '.join(skipped)}): it doesn't carry their settings")
        cdn = {k: [h for h in hs if h not in skipped] for k, hs in cdn.items()}
        if "cdn" in facts.get(c.name, {}) or (c.name not in facts and any(cdn.values())):
            params.update({k: ",".join(hs) or "none" for k, hs in cdn.items()})
            if any(cdn.values()):
                sec["dotdash_cdn_xhttp_path"] = path
        elif any(cdn.values()):
            waiting.append(f"{c.name}: its release predates CDN checks: update it to check {target.name}'s CDNs")
        docs[c.name] = {"parameters": params, "secrets": {"dotdash_id": ids[f"canary-{c.name}"], **sec}}

    # direct = false keeps the servers' domains out of what devices hold, so a
    # client machine fetches through an own-site relay, as a phone does: the
    # first its device sees, as client-config's pick has it.
    for c in net.client:
        group = net.group_of(c.device)
        if not ready[group]:
            waiting.append(f"{c.name}: waits for a server of {group} that applied its keys")
            continue
        urls = subscription_urls(net, state, facts, c.device, facts[ready[group][0].name], burnt, pools_kept)
        if not urls:
            waiting.append(f"{c.name}: waits for an own-site relay that {c.device}'s pools give it: "
                           "direct = false keeps the servers' URL out")
            continue
        docs[c.name] = {"secrets": {"subscription_url": urls[0], "proxy_password": state["passwords"][c.name]}}
    return docs, waiting
