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
        if any(any(f["paths"].values()) for f in seen):
            health[t.name] = {"fails": 0, "at": at}
        else:
            h["fails"] += 1
            h.setdefault("since", at)

    burnt = {t.name for t in targets if health.get(t.name, {}).get("fails", 0) >= BURN_AFTER}
    say = [f"burnt: server {s.name}: its canaries got through none of its paths in {health[s.name]['fails']} readings; "
           "reported only, as relays reach the servers" for s in net.server if s.name in burnt]
    relays = {r.name for r in net.relay if r.name in facts}
    out = {r.name for r in net.relay if r.name in burnt}
    if out and out >= relays:
        # Every relay down at once is likelier the canaries' own network than
        # every relay burnt in the same hour: devices keep them all.
        say.append(f"burnt: every relay ({', '.join(sorted(out))}) at once; all kept, check the canaries' network")
        return set(), say
    say += [f"burnt: relay {r}: its canaries got through none of its paths in {health[r]['fails']} readings; "
            f"left out of the servers' relays and pools until a canary gets through again; replace it" for r in sorted(out)]
    return out, say
