"""Which servers and relays the canaries find burnt: every canary watching one
got none of its paths through, while reaching the internet on its own, in
BURN_AFTER readings in a row. A canary refreshes its facts before every fleet
publish, so a reading is its facts' checked_at, and the same one read again
counts once."""

from .roster import Network

BURN_AFTER = 3


def _watched(f: dict, kind: str) -> tuple[str, str]:
    """The server name and address a canary watching this machine is given."""
    return (f["domain"], f["domain"]) if kind == "server" else (f["site"], f["entry_host"])


def judge(net: Network, facts: dict, health: dict) -> tuple[set[str], list[str]]:
    """Read the canaries' new verdicts into health, the state's record per
    machine, and return the burnt relays to leave out and what to say."""
    targets = [*net.server, *net.relay]
    for gone in set(health) - {t.name for t in targets}:
        del health[gone]
    for t in targets:
        if t.name not in facts:
            continue
        # A cdn-only relay's canaries check its own address, which no device gets.
        if facts[t.name].get("cdn_only"):
            health.pop(t.name, None)
            continue
        expect = _watched(facts[t.name], t.kind)
        # Facts about another target are from before the canary was pointed
        # here; a canary offline itself says nothing about its target.
        seen = [f for c in net.canary if c.watches == t.name and (f := facts.get(c.name))
                and (f.get("server"), f.get("address")) == expect and f.get("internet") is not False
                and isinstance(f.get("checked_at"), int) and isinstance(f.get("paths"), dict)]
        if not seen:
            continue
        at = max(f["checked_at"] for f in seen)
        h = health.setdefault(t.name, {"fails": 0, "at": 0})
        if at <= h["at"]:
            continue
        h["at"] = at
        # Per path too: up when any canary got through it this reading.
        ups = {p for f in seen for p, ok in f["paths"].items() if ok}
        h["paths"] = {p: 0 if p in ups else h.get("paths", {}).get(p, 0) + 1 for f in seen for p in f["paths"]}
        if ups:
            h["fails"] = 0
            h.pop("since", None)
        else:
            h["fails"] += 1
            h.setdefault("since", at)

    burnt = {t.name for t in targets if health.get(t.name, {}).get("fails", 0) >= BURN_AFTER}
    say = [f"burnt: server {s.name}: its canaries got through none of its paths in {health[s.name]['fails']} readings; "
           "reported only, as relays reach the servers" for s in net.server if s.name in burnt]
    relays = {r.name for r in net.relay if r.name in facts and not facts[r.name].get("cdn_only")}
    out = {r.name for r in net.relay if r.name in burnt}
    if out and out >= relays:
        # Every relay down at once is likelier the canaries' own network than
        # every relay burnt in the same hour: devices keep them all.
        say.append(f"burnt: every relay ({', '.join(sorted(out))}) at once; all kept, check the canaries' network")
        return set(), say
    say += [f"burnt: relay {r}: its canaries got through none of its paths in {health[r]['fails']} readings; "
            f"left out of the servers' relays and pools until a canary gets through again; replace it" for r in sorted(out)]
    return out, say


def blocked(net: Network, facts: dict, health: dict, burnt: set[str]) -> tuple[dict[str, set[str]], list[str]]:
    """The paths (reality, xhttp, mkcp) each relay's canaries got through none
    of in BURN_AFTER readings in a row while another path got through: devices
    stop getting those through it, and keep the rest. A path blocked on every
    relay that has it is likelier the canaries' network refusing that transport
    than every relay losing it in the same hour: kept everywhere, and said.
    A server's are reported only, as for a burnt server."""
    def out(name: str) -> set[str]:
        paths = health.get(name, {}).get("paths", {})
        gone = {p for p, n in paths.items() if n >= BURN_AFTER}
        return gone if gone != set(paths) else set()

    judged = [r.name for r in net.relay if r.name not in burnt and r.name in facts and not facts[r.name].get("cdn_only")]
    off = {r: gone for r in judged if (gone := out(r))}
    say = []
    for p in sorted({p for gone in off.values() for p in gone}):
        having = [r for r in judged if p in health.get(r, {}).get("paths", {})]
        if all(p in off.get(r, set()) for r in having):
            for r in having:
                off[r].discard(p)
            say.append(f"blocked: {p} on every relay that has it ({', '.join(having)}); kept, check whether the canaries' network blocks {p}")
    off = {r: gone for r, gone in off.items() if gone}
    say += [f"blocked: relay {r}: {', '.join(sorted(gone))} got through for none of its canaries in {BURN_AFTER} readings; "
            "devices get its other paths until one gets through again" for r, gone in sorted(off.items())]
    say += [f"blocked: server {s.name}: {', '.join(sorted(gone))} in {BURN_AFTER} readings; reported only"
            for s in net.server if s.name not in burnt and (gone := out(s.name))]
    return off, say
