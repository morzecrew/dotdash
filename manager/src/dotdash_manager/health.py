"""Which servers and relays the canaries find burnt: every canary watching one
got none of its paths through, while reaching the internet on its own, in
BURN_AFTER readings in a row. A canary refreshes its facts before every fleet
publish, so a reading is its facts' checked_at, and the same one read again
counts once."""

import time

from .roster import Network

BURN_AFTER = 3
# A canary's blocked_by, as the verdicts say it.
CAUSES = {"ip": "its canaries' network reaches no TCP port of it: its address is blocked",
          "sni": "its canaries' network blocks its name by SNI",
          "tls": "its canaries' network lets TCP through but not its TLS or REALITY",
          "freeze": "its canaries' network freezes its connections partway",
          "burst": "its canaries' network freezes REALITY once a page opens several connections at once"}
# The event log keeps this many, the newest.
EVENTS = 2000
# Each machine keeps this many of its readings' latencies per path, the newest.
LATENCIES = 24
# A canary's reading counts beside the newest of the others watching the same
# machine only this many seconds older: canaries publish hourly, each at a
# moment of its own, so one that missed a publish, or went quiet, falls out
# rather than holding an old success against a fresh failure.
FRESH = 90 * 60
# A canary's clock may run this far ahead of the manager's. A reading from
# further on is dropped: it would make every honest one look old (FRESH), and
# until real time caught up, keep the verdict it gave (a reading counts once).
AHEAD = 600
# A site's certificate with fewer days left than this is said (certs).
CERT_DAYS = 14


def _watched(f: dict, kind: str) -> tuple[str, str]:
    """The server name and address a canary watching this machine is given."""
    return (f["domain"], f["domain"]) if kind == "server" else (f["site"], f["entry_host"])


def fronts(f: dict) -> list[str]:
    """The CDN names in front of a relay, by its facts: its cdn_hosts, then its
    door's (origin_host), each without the path a gateway gives."""
    return [*f.get("cdn_hosts", []), *(o.split("/")[0] for o in f.get("origin_host", "").split(",") if o)]


def got(f: dict, target: dict) -> dict:
    """What a canary's facts say got through to a target, by the target's
    facts: the paths, and each CDN in front that the relay names now, as
    cdn:<name>. A cdn-only relay's canaries check its own address too, which
    no device gets: its CDNs alone count."""
    mine = fronts(target)
    cdn = {f"cdn:{h}": ok for h, ok in (f.get("cdn") or {}).items() if h in mine}
    return cdn if target.get("cdn_only") else {**f["paths"], **cdn}


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


def _median(values: list) -> int:
    values = sorted(values)
    return values[(len(values) - 1) // 2]


def record(h: dict, seen: list[dict]) -> None:
    """One reading's latencies into a machine's record: per path, the
    median of what its canaries took through it (latency_ms), and
    "direct", the median of their own network's leg (direct_ms); the
    newest LATENCIES of each. Canaries from before facts carried them add
    nothing."""
    got: dict[str, list] = {}
    for f in seen:
        for p, ms in (f.get("latency_ms") or {}).items():
            if isinstance(ms, int) and ms >= 0:
                got.setdefault(p, []).append(ms)
        if isinstance(f.get("direct_ms"), int) and f["direct_ms"] >= 0:
            got.setdefault("direct", []).append(f["direct_ms"])
    for p, values in got.items():
        h.setdefault("latency", {}).setdefault(p, []).append(_median(values))
        del h["latency"][p][:-LATENCIES]


def judge(net: Network, facts: dict, health: dict, rows: dict | None = None,
          now: float | None = None) -> tuple[set[str], list[str]]:
    """Read the canaries' new verdicts into health, the state's record per
    machine, and return the burnt relays to leave out and what to say. rows,
    the machines' own fleet rows (Morzer.rows), say whether each looks
    blocked or down. A reading from more than AHEAD past now is dropped."""
    rows = rows or {}
    now = time.time() if now is None else now
    targets = [*net.server, *net.relay]
    for gone in set(health) - {t.name for t in targets}:
        del health[gone]
    for t in targets:
        if t.name not in facts:
            continue
        only = facts[t.name].get("cdn_only")
        expect = _watched(facts[t.name], t.kind)
        # Facts about another target are from before the canary was pointed
        # here.
        watching = [f for c in net.canary if c.watches == t.name and (f := facts.get(c.name))
                    and (f.get("server"), f.get("address")) == expect and isinstance(f.get("paths"), dict)
                    and got(f, facts[t.name])]
        # A cdn-only relay none of whose canaries checks its CDNs is not judged.
        if only and not watching:
            health.pop(t.name, None)
            continue
        # A canary offline itself says nothing about its target.
        seen = [f for f in watching if f.get("internet") is not False
                and isinstance(f.get("checked_at"), int) and f["checked_at"] <= now + AHEAD]
        if not seen:
            continue
        at = max(f["checked_at"] for f in seen)
        seen = [f for f in seen if at - f["checked_at"] <= FRESH]
        h = health.setdefault(t.name, {"fails": 0, "at": 0})
        if at <= h["at"]:
            continue
        h["at"] = at
        # Per path too, a CDN in front as one: up when any canary got through
        # it this reading.
        ups = {p for f in seen for p, ok in got(f, facts[t.name]).items() if ok}
        # What the canaries found of the relay's own address, REALITY's
        # included, which says nothing of a cdn-only relay.
        own = [] if only else seen
        record(h, own)
        h["paths"] = {p: 0 if p in ups else h.get("paths", {}).get(p, 0) + 1
                      for f in seen for p in got(f, facts[t.name])}
        # REALITY with its hello split (a canary's reality_split): up this
        # reading when any canary got through so, else readings in a row it hasn't.
        # What the canaries' network finds stopping REALITY (a canary's
        # blocked_by: ip, sni, tls or freeze), the commonest this reading.
        causes = [f["blocked_by"] for f in own if f.get("blocked_by") in CAUSES]
        if causes:
            h["cause"] = max(set(causes), key=causes.count)
        else:
            h.pop("cause", None)
        said = [f["reality_split"] for f in own if isinstance(f.get("reality_split"), bool)]
        if said:
            h["split"] = 0 if any(said) else h.get("split", 0) + 1
        else:
            h.pop("split", None)
        # A relay that gets through only with its hello split is reachable:
        # devices' Xray configs split it (splits), so it is not burnt.
        if ups or h.get("split") == 0:
            h["fails"] = 0
            h.pop("since", None)
        else:
            h["fails"] += 1
            h.setdefault("since", at)

    burnt = {t.name for t in targets if health.get(t.name, {}).get("fails", 0) >= BURN_AFTER}
    def note(name: str, advice: str = "") -> str:
        """What blocks it, as its canaries' network finds, the row's word on
        it, then the advice unless the row says it is down."""
        verdict, why = alive(rows.get(name))
        cause = CAUSES.get(health.get(name, {}).get("cause", ""), "")
        return ((f"; {cause}" if cause else "") + (f"; {why}" if why else "")
                + (f"; {advice}" if advice and verdict != "down" else ""))

    say = [f"burnt: server {s.name}: its canaries got through none of its paths in {health[s.name]['fails']} readings; "
           f"reported only, as relays reach the servers{note(s.name)}" for s in net.server if s.name in burnt]
    relays = {r.name for r in net.relay if r.name in facts and (not facts[r.name].get("cdn_only") or r.name in health)}
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
    """The paths (reality, xhttp, mkcp, hysteria2) each relay's canaries got through none
    of in BURN_AFTER readings in a row while another path, or REALITY with its
    hello split, got through: devices
    stop getting those through it, and keep the rest. A path blocked on every
    relay that has it is likelier the canaries' network refusing that transport
    than every relay losing it in the same hour: kept everywhere, and said.
    A server's are reported only, as for a burnt server. So is a CDN in front
    of a relay (cdn:<name>): off= takes no CDN, and devices keep its links."""
    def out(name: str) -> set[str]:
        h = health.get(name, {})
        paths = h.get("paths", {})
        gone = {p for p, n in paths.items() if n >= BURN_AFTER}
        # Every path blocked burns it instead, unless its split hello gets
        # through: then off= takes them from share links, and split keeps
        # REALITY in devices' Xray configs.
        return gone if gone != set(paths) or h.get("split") == 0 else set()

    judged = [r.name for r in net.relay if r.name not in burnt and r.name in facts]
    off = {r: gone for r in judged if (gone := out(r))}
    cdns = {r: sorted(p.removeprefix("cdn:") for p in gone if p.startswith("cdn:")) for r, gone in off.items()}
    off = {r: {p for p in gone if not p.startswith("cdn:")} for r, gone in off.items()}
    say = [f"blocked: relay {r}: its CDN {', '.join(names)} got through for none of its canaries in {BURN_AFTER} "
           "readings; reported only, as off= takes no CDN: check the CDN's settings and the relay's site"
           for r, names in sorted(cdns.items()) if names]
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


def certs(net: Network, facts: dict) -> list[str]:
    """A line for each server and relay whose site's certificate runs out in
    under CERT_DAYS, by its facts' cert_days (absent: unknown, nothing said).
    Renewal starts well before (a month ahead, for a 90-day certificate), so
    this is renewal failing; once it runs out, XHTTP on the site, Hysteria2
    and the CDN paths break while REALITY works, which canaries read as
    censorship."""
    out = []
    for m in [*net.server, *net.relay]:
        days = facts.get(m.name, {}).get("cert_days")
        if isinstance(days, int) and days < CERT_DAYS:
            left = f"ran out {-days} day(s) ago" if days < 0 else f"runs out in {days} day(s)"
            out.append(f"certificate: {m.kind} {m.name}: its site's certificate {left}: renewal is failing, check its "
                       "ACME (for acme-dns, that it runs and answers)")
    return out


def splits(net: Network, health: dict, burnt: set[str] | frozenset[str] = frozenset()) -> tuple[set[str], list[str]]:
    """The servers and relays devices should reach with their REALITY hello
    split into TLS records: REALITY got through for none of their canaries in
    BURN_AFTER readings, while the split hello did in the last one. That is a
    box blocking the name by SNI, reassembling TCP but not TLS records
    (dotdash-lab #50). It holds while that stays so: REALITY back, or the split
    failing too, turns it off. A server gets hello_split; a relay split on its
    line, beside off=reality, which keeps the link out of share links (they
    can't split) while devices' Xray configs keep it, split. A burnt relay
    stays out."""
    def on(name: str) -> bool:
        h = health.get(name, {})
        return h.get("paths", {}).get("reality", 0) >= BURN_AFTER and h.get("split") == 0
    servers = {s.name for s in net.server if on(s.name)}
    relays = {r.name for r in net.relay if on(r.name) and r.name not in burnt}
    say = [f"split: server {n}: REALITY gets through only with its hello split into TLS records, a block on its name by SNI; "
           "devices' Xray configs split it (hello_split), share links can't" for n in sorted(servers)]
    say += [f"split: relay {n}: REALITY gets through only with its hello split into TLS records, a block on its site's name "
            "by SNI; devices' Xray configs split it through the relay, share links lose it (off=reality)" for n in sorted(relays)]
    return servers | relays, say


def events(before: dict, after: dict, stood: dict, stands: dict, now: int,
           roster: set[str] | frozenset[str] = frozenset()) -> list[list]:
    """What changed between two health records (judge's, before and after a
    sync), as [at, machine, what], for report: watched (its canaries' first
    reading), burnt, back, gone (out of the roster), unwatched (in the roster,
    its servers' and relays' names, but judged no more: turned cdn-only with
    no canary checking its CDNs), off:<path> and on:<path>, a CDN in front as
    cdn:<name>; and for a spare, stands-in:<relay> and waits,
    from health.spares' stands before (stood) and now. at is the reading's
    checked_at, else now."""
    out = []
    for name in sorted(set(before) | set(after)):
        b, a = before.get(name), after.get(name)
        if a is None:
            out.append([now, name, "unwatched" if name in roster else "gone"])
            continue
        at = a.get("at") or now
        if b is None:
            out.append([at, name, "watched"])
            b = {}
        was, fails = b.get("fails", 0), a.get("fails", 0)
        if was < BURN_AFTER <= fails:
            out.append([at, name, "burnt"])
        elif was >= BURN_AFTER > fails:
            out.append([at, name, "back"])
        for p, n in sorted(a.get("paths", {}).items()):
            m = b.get("paths", {}).get(p, 0)
            if m < BURN_AFTER <= n:
                out.append([at, name, f"off:{p}"])
            elif m >= BURN_AFTER > n:
                out.append([at, name, f"on:{p}"])
    out += [[now, s, f"stands-in:{r}"] for s, r in sorted(stands.items()) if stood.get(s) != r]
    out += [[now, s, "waits"] for s in sorted(stood) if s not in stands]
    return out
