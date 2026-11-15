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


def alive(row: dict | None) -> tuple[str, str]:
    """What a machine's own fleet row says of it, when one verifies, as
    (blocked | down | "", why): running while its canaries get nothing through
    is blocked on the way; a row gone quiet, or services down, is likelier the
    machine itself."""
    if not row:
        return "", ""
    if row["stale"]:
        return "down", f"its own fleet row is {row['age']} old, so it may be down rather than blocked: check it first"
    services, running = row["services"], row["running"]
    if row["problem"] or (services is not None and running is not None and running < services):
        return "down", (f"its own fleet row says {'?' if running is None else running} of "
                        f"{'?' if services is None else services} services run: likelier down than blocked, fix it first")
    return "blocked", f"its own fleet row ({row['age']} old) says it runs: blocked on the way, not down"


def judge(net: Network, facts: dict, health: dict, rows: dict | None = None) -> tuple[set[str], list[str]]:
    """Read the canaries' new verdicts into health, the state's record per
    machine, and return the burnt relays to leave out and what to say. rows,
    the machines' own fleet rows (Morzer.rows), say whether each looks
    blocked or down."""
    rows = rows or {}
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
    def note(name: str, advice: str = "") -> str:
        """The row's word on it, then the advice unless the row says it is down."""
        verdict, why = alive(rows.get(name))
        return (f"; {why}" if why else "") + (f"; {advice}" if advice and verdict != "down" else "")

    say = [f"burnt: server {s.name}: its canaries got through none of its paths in {health[s.name]['fails']} readings; "
           f"reported only, as relays reach the servers{note(s.name)}" for s in net.server if s.name in burnt]
    relays = {r.name for r in net.relay if r.name in facts and not facts[r.name].get("cdn_only")}
    out = {r.name for r in net.relay if r.name in burnt}
    if out and out >= relays:
        # Every relay down at once is likelier the canaries' own network than
        # every relay burnt in the same hour: devices keep them all.
        say.append(f"burnt: every relay ({', '.join(sorted(out))}) at once; all kept, check the canaries' network")
        return set(), say
    say += [f"burnt: relay {r}: its canaries got through none of its paths in {health[r]['fails']} readings; "
            f"left out of the servers' relays and pools until a canary gets through again{note(r, 'replace it')}"
            for r in sorted(out)]
    return out, say


def spares(net: Network, facts: dict, health: dict, burnt: set[str]) -> tuple[set[str], dict[str, str], list[str]]:
    """Spare relays (spare = true) stand in for burnt ones at the next sync,
    rather than when someone notices. Each burnt relay, in roster order, gets
    the first spare not burnt itself, those its canaries got through to first,
    and the spare takes its place in the pools. A spare stands in only while
    the relay it replaces is burnt: one that comes back sends it back to
    waiting. Returns the spares held back (left out, as burnt relays are), each
    standing spare's burnt relay, and what to say."""
    def warm(name: str) -> bool:
        h = health.get(name, {})
        return bool(h.get("at")) and h.get("fails", 0) == 0

    ready = [r.name for r in net.relay
             if r.spare and r.name in facts and r.name not in burnt and not facts[r.name].get("cdn_only")]
    ready.sort(key=lambda name: not warm(name))
    stands, say = {}, []
    for r in [r.name for r in net.relay if not r.spare and r.name in burnt]:
        if not ready:
            say.append(f"spare: none left for burnt relay {r}; add a relay with spare = true, or replace {r}")
            continue
        s = ready.pop(0)
        stands[s] = r
        unchecked = "" if warm(s) else " (no canary has got through to it yet: check it)"
        say.append(f"spare: {s} stands in for burnt relay {r}, in its pools{unchecked}; replace {r}, "
                   f"then make {s} a regular relay (spare = false) and add a new spare")
    # Every spare not standing in waits, a cdn-only one too, which never stands in.
    held = {r.name for r in net.relay if r.spare and r.name in facts} - set(stands) - burnt
    return held, stands, say


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
