"""status: one line per machine, with its release, what it did with the newest
document published for it, its health, how old the facts the manager holds
are and what its canaries found; then the topology. From what morzer returns
(each machine's fleet row, state ls's newest serials) and what the last sync
kept. Pure: it reads nothing and writes nothing, and prints no secret."""

from datetime import datetime

from .health import BURN_AFTER
from .report import span
from .roster import Network


def document(published: int, sync: dict | None) -> tuple[str, str]:
    """What a machine did with the newest document published for it, and
    whether that is ok, pending or bad. The row keeps the last document
    applied and the last refused, so a refusal older than an apply is past."""
    if not published:
        return "none published", "ok"
    if sync is None:
        return "not following the manager", "bad"
    if not sync["enabled"]:
        return "sync off", "bad"
    applied, refused = sync["applied"] or {}, sync["refused"] or {}
    if applied.get("serial", 0) >= published:
        waits = f"; for the update: {', '.join(sync['pending'])}" if sync["pending"] else ""
        return f"applied {published}{waits}", "ok"
    if refused.get("serial", 0) >= published:
        why = refused["class"] or refused["step"] or "refused"
        return f"REFUSED {published} {why}" + (f": {', '.join(refused['names'])}" if refused["names"] else ""), "bad"
    fetch = f", last fetch {sync['fetch']}" if sync["fetch"] not in (None, "ok") else ""
    return f"pending {published}{fetch}", "pending"


def health(row: dict | None) -> tuple[str, bool]:
    """Its own fleet row's word on it, and whether that is bad: stale, or
    services down."""
    if row is None:
        return "no verified row", True
    age = row["age"].replace("m0s", "m")
    if row["stale"]:
        return f"STALE, row {age}", True
    services, running = row["services"], row["running"]
    if services is None or running is None:
        return f"not checked, row {age}", bool(row["problem"])
    return f"{running}/{services} up, row {age}", bool(row["problem"]) or running < services


def canaries(net: Network, st: dict, name: str, kind: str, now: int) -> str:
    """For a server or relay, its paths as its canaries found them at the
    last sync; for a canary, how old its reading is."""
    if kind == "canary":
        f = st.get("facts", {}).get(name, {}).get("facts", {})
        if "checked_at" not in f:
            return "no reading"
        return ("its network offline, " if f.get("internet") is False else "") + f"read {span(now - f['checked_at'])} ago"
    if kind == "client":
        return "-"
    if not any(c.watches == name for c in net.canary):
        return "unwatched"
    h = st.get("health", {}).get(name)
    if not h:
        return "no reading yet"
    said = lambda n: "ok" if n == 0 else "off" if n >= BURN_AFTER else f"failed {n}x"
    paths = ", ".join(f"{p} {said(n)}" for p, n in sorted(h.get("paths", {}).items()))
    return ("BURNT: " if h.get("fails", 0) >= BURN_AFTER else "") + (paths or "no path")


def epoch(at: str | None) -> float | None:
    try:
        return datetime.fromisoformat(at).timestamp() if at else None
    except ValueError:
        return None


def devices(m, st: dict, row: dict | None) -> str | None:
    """A relay whose device list, by the digest its facts carry, is not the
    one the manager last sent it: changed on the relay by hand. Said only of
    facts read after its last apply, which carry what that apply gave it."""
    kept = st.get("facts", {}).get(m.name)
    has = (kept or {}).get("facts", {}).get("clients")
    sent = st.get("published", {}).get(m.id, {}).get("clients")
    applied = epoch((((row or {}).get("sync") or {}).get("applied") or {}).get("at"))
    if not (has and sent and applied) or kept["at"] <= applied or has["digest"] == sent:
        return None
    return (f"{m.name}: its device list ({has['count']}, digest {has['digest']}) is not the one the manager sent "
            f"(digest {sent}): changed on the relay by hand? The manager's next document for it puts it back")


def table(rows: list[list[str]]) -> list[str]:
    widths = [max(len(r[i]) for r in rows) for i in range(len(rows[0]))]
    return ["  ".join(c.ljust(w) for c, w in zip(r, widths, strict=True)).rstrip() for r in rows]


def machines(net: Network, st: dict, rows: dict, published: dict, now: int) -> tuple[list[str], bool, bool]:
    """The table and its notes, whether any document is still pending, and
    whether anything is bad: refused, not followed, stale, down, or a relay's
    device list not the one sent."""
    out = [["machine", "kind", "release", "document", "health", "facts", "canaries"]]
    notes, pending, bad = [], False, False
    for m in net.machines:
        if not m.joined:
            out.append([m.name, m.kind, "-", f"not joined: run join {m.name}", "-", "-", "-"])
            continue
        row = rows.get(m.name)
        doc, said = document(published.get(m.name, 0), row and row["sync"])
        well, down = health(row)
        kept = st.get("facts", {}).get(m.name)
        facts = "-" if m.kind == "client" else span(now - kept["at"]) if kept else "none"
        release = (row or {}).get("version") or "?"
        if row and row["staged"]:
            release += f" (staged {row['staged']})"
        out.append([m.name, m.kind, release, doc, well, facts, canaries(net, st, m.name, m.kind, now)])
        if row and row["facts_problem"]:
            notes.append(f"{m.name}: its last facts run didn't replace them: {row['facts_problem']}")
        stale = devices(m, st, row) if m.kind == "relay" and said == "ok" else None
        notes += [stale] if stale else []
        pending |= said == "pending"
        bad |= said == "bad" or down or bool(stale)
    return table(out) + (["", *notes] if notes else []), pending, bad


def topology(net: Network, st: dict) -> list[str]:
    """The servers and what they serve, each relay's entries, its via, and
    whether it is a spare, standing in, standby, burnt or has paths off; the
    pools, the desktops and what each canary watches. As the last sync read
    the facts. Addresses and names, never a key or a path."""
    facts = {n: k["facts"] for n, k in st.get("facts", {}).items()}
    hl, stands = st.get("health", {}), st.get("stands", {})
    out = ["", "topology, from the facts the last sync read:"]
    for s in net.server:
        f = facts.get(s.name)
        if not f:
            out.append(f"  server {s.name}: no facts yet")
            continue
        serves = ["reality", "xhttp"] + ([f"xhttp-reality {f['xhttp_reality_port']}"] if "xhttp_reality_port" in f else [])
        serves += [f"mkcp {f['kcp']['port']}"] if "kcp" in f else []
        serves += [f"hy2 {f['hysteria2_port']}"] if "hysteria2_port" in f else []
        serves += [f"cdn {','.join(s.cdn_hosts)}"] if s.cdn_hosts else []
        out.append(f"  server {s.name}: {f['domain']}:{f['https_port']}: {', '.join(serves)}")
    for r in net.relay:
        f, h = facts.get(r.name), hl.get(r.name, {})
        marks = [f"via {', '.join(r.via)} ({r.via_link})"] if r.via else []
        marks += ["spare" + (f", standing in for {stands[r.name]}" if r.name in stands else "")] if r.spare else []
        marks += ["standby"] if r.standby else []
        marks += ["BURNT"] if h.get("fails", 0) >= BURN_AFTER else []
        off = sorted(p for p, n in h.get("paths", {}).items() if n >= BURN_AFTER)
        marks += [f"off={','.join(off)}"] if off and h.get("fails", 0) < BURN_AFTER else []
        if not f:
            out.append(f"  relay {r.name}: no facts yet" + "".join(f"; {x}" for x in marks))
            continue
        entries = [] if f.get("cdn_only") else ["reality"]
        entries += ["xhttp"] if "own_site" in f else []
        entries += [f"mkcp {f['kcp']['port']}"] if "kcp" in f else []
        entries += [f"hy2 {f['hysteria2']['port']}"] if "hysteria2" in f else []
        entries += [f"cdn {','.join(f['cdn_hosts'])}"] if f.get("cdn_hosts") else []
        # A gateway's path after an origin name may be a token: the name alone.
        if f.get("origin_host"):
            entries.append("origin " + ",".join(o.split("/")[0] for o in f["origin_host"].split(",")))
        marks = ([f"name {f['name']}"] if f.get("name") else []) + (["cdn-only"] if f.get("cdn_only") else []) + marks
        out.append(f"  relay {r.name}: {f['entry_host']}, site {f['site']}: {', '.join(entries)}"
                   + "".join(f"; {x}" for x in marks))
    out += [f"  pool {p}: {', '.join(ms)}" for p, ms in net.pools.items()]
    out += [f"  desktops: {', '.join(net.desktops)}"] if net.desktops else []
    out += [f"  canary {c.name} watches {c.watches}" for c in net.canary]
    out += [f"  client {c.name} follows {c.device}" for c in net.client]
    return out
