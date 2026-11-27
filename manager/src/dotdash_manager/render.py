"""Every machine's document, from the roster, the manager's state and the facts
at hand. Pure: it reads nothing and writes nothing."""

import hashlib
import json
from collections import Counter

from . import rotate
from .roster import Network
from .state import check_ids, public_key

# What a server's facts say that client-config takes for every server alike.
SHARED = ("https_port", "xhttp_reality_port", "kcp", "hysteria2_port")


def relay_line(f: dict, off: set[str] | frozenset[str] = frozenset(), split: bool = False,
               standby: bool = False) -> str:
    """The relay's line for a server's relays, as its relay-entry task prints
    it, with the paths its canaries find blocked (health.blocked) as off=,
    split when they got REALITY through only with its hello split
    (health.splits), and standby when the roster says so."""
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
    if f.get("cdn_path"):
        line += f" cdnpath={f['cdn_path']}"
    if f.get("origin_host"):
        line += f" origin={f['origin_host']}"
    if f.get("cdn_only"):
        line += " cdn-only"
    if f.get("name"):
        line += f" name={f['name']}"
    if off:
        line += " off=" + ",".join(sorted(off))
    if split:
        line += " split"
    if standby:
        line += " standby"
    return line


def via_line(f: dict, link: str) -> str:
    """A relay's line for another's via: its link's five fields, and with
    XHTTP the path through its own site, which that needs."""
    line = " ".join(relay_line(f).split()[:5])
    return line + (f" own-site {f['own_site']['xhttp_path']}" if link == "xhttp" else "")


def clients_digest(vless_clients: str) -> str:
    """The digest of a device list, as a relay's facts and the server's
    relay-config take it: the first 8 hex characters of the sha256 of its
    ids, sorted, one per line."""
    ids = sorted(f[0] for f in map(str.split, vless_clients.splitlines()) if f and not f[0].startswith("#"))
    return hashlib.sha256("".join(f"{i}\n" for i in ids).encode()).hexdigest()[:8]


def applied_keys(net: Network, state: dict, facts: dict) -> list:
    """The servers whose facts carry the manager's public key: those that
    applied its document, and so its keys."""
    pbk = public_key(state["keys"]["reality_key"])
    return [s for s in net.server if facts.get(s.name, {}).get("public_key") == pbk]


def kept_pools(net: Network, facts: dict, burnt: set[str] | frozenset[str],
               stands: dict[str, str]) -> tuple[dict[str, list[str]], list[str]]:
    """The pools as the servers get them, each with its members kept, and
    what to say: a burnt or held relay's hosts out, a spare standing in for
    one (stands: spare, its burnt relay) in its place. A pool left with no
    member is left out."""
    # A pool naming a relay left out would name nothing: the server warns.
    # An origin name may carry its gateway's path, <host>/<path>: pools name the host.
    hosts = lambda name: [facts[name]["entry_host"], *facts[name].get("cdn_hosts", []),
                          *(o.split("/")[0] for o in facts[name].get("origin_host", "").split(",") if o)]
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
    """A device's subscription URLs, as client-config prints them: the lead
    server's (the first that applied the keys), unless direct = false keeps
    it out, then the same through each own-site relay the device sees, in
    the servers' relays order. A device in a pool sees its pools' relays and
    those in none; one in none sees all. The token is subscription.sh's:
    sha256 of <subscription_key>:<id>, its first 32 hex characters."""
    token = hashlib.sha256(f"{state['keys']['subscription_key']}:{state['ids'][device]}".encode()).hexdigest()[:32]
    port = "" if lead["https_port"] == 443 else f":{lead['https_port']}"
    listed = {h for kept in pools_kept.values() for h in kept}
    mine = {h for kept in pools_kept.values() if device in kept for h in kept}
    sites = [f["site"] for r in net.relay if "own_site" in (f := facts.get(r.name, {})) and r.name not in burnt
             and not f.get("cdn_only") and (not mine or f["entry_host"] in mine or f["entry_host"] not in listed)]
    server = [] if net.direct is False else [f"https://{lead['domain']}{port}/{token}"]
    return server + [f"https://{site}/{token}" for site in sites]


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
    check_ids(ids)
    pbk = public_key(keys["reality_key"])
    known = [s for s in net.server if s.name in facts]
    ready = applied_keys(net, state, facts)
    waiting = [f"{s.name}: {'no facts yet' if s.id else 'not joined'}" for s in [*net.server, *net.relay] if s.name not in facts]
    waiting += [f"{s.name}: has not applied the keys yet" for s in known if s not in ready]
    def vless(kind: str, relay: str | None = None) -> str:
        return "\n".join(f"{ids[n]} {n}" + (" desktop" if n in net.desktops else "") for n in net.clients_of(kind, relay))

    docs = {}

    off = off or {}
    relays = "\n".join(relay_line(facts[r.name], off.get(r.name, frozenset()), r.name in split, r.standby)
                       for r in net.relay if r.name in facts and r.name not in burnt)
    pools_kept, more = kept_pools(net, facts, burnt, stands or {})
    waiting += more
    pools = "\n".join(f"{p} {' '.join(kept)}" for p, kept in pools_kept.items())
    for s in net.server:
        others = [facts[o.name]["domain"] for o in known if o is not s]
        doc = {
            "parameters": {
                "servers": ",".join(["self", *others]),
                "subscription": str(net.subscription).lower(),
                "cdn_hosts": ",".join(s.cdn_hosts) or "none",
            },
            "secrets": {"vless_clients": vless("server"), **keys},
        }
        # Only when the roster says: a server released before direct refuses it.
        if net.direct is not None:
            doc["parameters"]["direct"] = str(net.direct).lower()
        if net.cdn_extra is not None:
            doc["parameters"]["cdn_extra"] = "\n".join(f"{h} {json.dumps(x)}" for h, x in net.cdn_extra.items()) or "none"
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
            # The retired key out of the server's secret store, and so out of
            # its backups from then on, not only unused.
            doc.setdefault("unset", {})["secrets"] = [f"{k}_second" for k in rotate.KEYS]
        if s.name in split:
            doc["parameters"]["hello_split"] = "true"
        elif s.name in state.get("split", []):
            doc["parameters"]["hello_split"] = "false"
        docs[s.name] = doc

    lead = facts[ready[0].name] if ready else None
    # client-config gives every server in servers its own server's ports, mKCP
    # header and opener and profiles (each present or not): where those
    # differ, its subscriptions carry dead links to the others.
    differ = [k for k in SHARED if len({json.dumps(facts[s.name].get(k), sort_keys=True) for s in ready}) > 1]
    if lead and differ:
        waiting.append(f"servers differ in {', '.join(differ)}: each server's links name the others with its own, so "
                       "some are dead; give every server the same profiles and ports"
                       + (f"; relays take {lead['https_port']}, {ready[0].name}'s" if "https_port" in differ else ""))
    for r in net.relay:
        if not lead:
            waiting.append(f"{r.name}: waits for a server that applied the keys")
            continue
        # via: the other relays' links, the first five fields of their lines.
        # A relay with facts says whether its release takes via; one with none
        # yet installs a release that does, and goes via them from the start.
        missing = [v for v in r.via if v not in facts]
        if missing:
            waiting.append(f"{r.name}: goes via {', '.join(missing)}, which has no facts yet")
            continue
        siteless = [v for v in r.via if r.via_link == "xhttp" and "own_site" not in facts[v]]
        if siteless:
            waiting.append(f"{r.name}: goes via {', '.join(siteless)} by XHTTP, which needs their own site")
            continue
        takes_via = facts.get(r.name, {}).get("via", r.name not in facts)
        if r.via and not takes_via:
            waiting.append(f"{r.name}: its release predates via: update it")
            continue
        doc = docs[r.name] = {
            "parameters": {
                "dotdash_servers": ",".join(facts[s.name]["domain"] for s in ready),
                "dotdash_address": "none",
                "dotdash_port": str(lead["https_port"]),
                "dotdash_public_key": pbk,
                "ipv6": net.ipv6,
            },
            "secrets": {
                "vless_clients": vless("relay", r.name),
                "dotdash_id": ids[f"relay-{r.name}"],
                "dotdash_encryption": lead["encryption"],
                "dotdash_short_id": keys["reality_short_id"],
            },
        }
        if r.via:
            doc["parameters"]["via"] = "\n".join(via_line(facts[v], r.via_link) for v in r.via)
            doc["parameters"]["via_link"] = r.via_link
            if r.via_link == "xhttp":
                doc["parameters"]["via_fingerprint"] = r.via_fingerprint
        elif r.name in state.get("via", []):
            # Off via again: unset only where an earlier document set it (the
            # state's via). A relay whose release doesn't let a document manage
            # via refuses any naming it, and so would take no change at all.
            doc["unset"] = {"parameters": ["via", "via_link", "via_fingerprint"]}

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
        if not lead:
            waiting.append(f"{c.name}: waits for a server that applied the keys")
            continue
        urls = subscription_urls(net, state, facts, c.device, lead, burnt, pools_kept)
        if not urls:
            waiting.append(f"{c.name}: waits for an own-site relay that {c.device}'s pools give it: "
                           "direct = false keeps the servers' URL out")
            continue
        docs[c.name] = {"secrets": {"subscription_url": urls[0], "proxy_password": state["passwords"][c.name]}}
    return docs, waiting
