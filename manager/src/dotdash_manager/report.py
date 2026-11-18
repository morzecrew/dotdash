"""What the manager's event log (health.events) says of each server and relay:
since when its canaries watch it, how long it lasted before it first burnt,
how often it burnt and for how long, which of its paths went off, how often
a spare stood in; and across the relays, how long one lasts. Machines gone
from the roster stay in it: how long a replaced relay lasted is the point.
Then how long each path lasted before its first block, the relays' lifetimes
per provider (the roster's own labels, state's labels), and where the time
goes, from the canaries' latencies (health.record). Pure: it reads nothing
and writes nothing."""

import calendar
import statistics
import time
from collections import Counter

from .roster import Network


def span(seconds: float) -> str:
    seconds = int(max(seconds, 0))
    d, h, m = seconds // 86400, seconds % 86400 // 3600, seconds % 3600 // 60
    return f"{d}d {h}h" if d else f"{h}h {m}m" if h else f"{m}m"


def day(t: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(t))


def history(events: list, name: str, now: int) -> dict:
    """One machine's life from the log: first watched, its burns as
    (from, to) with to None while burnt, when it left the roster, paths off,
    and how often it stood in as a spare."""
    mine = sorted((e for e in events if e[1] == name), key=lambda e: e[0])
    h = {"watched": None, "burns": [], "gone": None, "off": Counter(), "first_off": {}, "stood": 0}
    for at, _, what in mine:
        if what == "watched" and h["watched"] is None:
            h["watched"] = at
        elif what == "burnt":
            h["burns"].append([at, None])
        elif what == "back" and h["burns"] and h["burns"][-1][1] is None:
            h["burns"][-1][1] = at
        elif what == "gone":
            h["gone"] = at
        elif what.startswith("off:"):
            h["off"][what[4:]] += 1
            h["first_off"].setdefault(what[4:], at)
        elif what.startswith("stands-in:"):
            h["stood"] += 1
    end = h["gone"] or now
    h["down"] = sum((to or end) - since for since, to in h["burns"])
    h["burnt_now"] = bool(h["burns"]) and h["burns"][-1][1] is None and not h["gone"]
    first = h["burns"][0][0] if h["burns"] else None
    h["lasted"] = None if h["watched"] is None else (first or end) - h["watched"]
    h["lasting"] = first is None  # still going: a lower bound
    return h


PATHS = ("reality", "xhttp", "xhttp-reality", "mkcp", "hysteria2")


def _median(values: list) -> int:
    values = sorted(values)
    return values[(len(values) - 1) // 2]


def paths(names: list[str], events: list, now: int, health: dict) -> list[str]:
    """How long each path of each server and relay lasted before it was first
    blocked, a burn included ("+": never yet, a lower bound), and per path
    across the relays, the median of those blocked: which transport lasts.
    A machine's paths are those its canaries check (health) and those that
    ever went off (the log), so a gone relay's count too."""
    rows, blocked, never = [], {p: [] for p in PATHS}, {p: [] for p in PATHS}
    relays = set()
    for name in names:
        h = history(events, name, now)
        if h["watched"] is None:
            continue
        have = set(health.get(name, {}).get("paths", {})) | set(h["first_off"])
        if not have:
            continue
        end = h["gone"] or now
        cells = []
        for p in PATHS:
            if p not in have:
                cells.append("-")
            elif p in h["first_off"]:
                cells.append(span(h["first_off"][p] - h["watched"]))
                blocked[p].append(h["first_off"][p] - h["watched"])
            else:
                cells.append(span(end - h["watched"]) + "+")
                never[p].append(end - h["watched"])
        rows.append((name, cells))
        relays.add(name)
    if not rows:
        return []
    width = max(len(p) for p in PATHS) + 1
    lines = ["", "paths: how long each lasted before it was first blocked (+: never yet)",
             f"{'machine':12} " + " ".join(f"{p:>{width}}" for p in PATHS)]
    lines += [f"{name:12} " + " ".join(f"{c:>{width}}" for c in cells) for name, cells in rows]
    summary = []
    for p in PATHS:
        if blocked[p]:
            summary.append(f"{p} {span(statistics.median(blocked[p]))} ({len(blocked[p])} blocked"
                           + (f", {len(never[p])} never)" if never[p] else ")"))
        elif never[p]:
            summary.append(f"{p} never blocked ({len(never[p])}, {span(max(never[p]))} longest)")
    lines.append("median to first block: " + "; ".join(summary))
    return lines


def providers(names: list[str], events: list, now: int, labels: dict) -> list[str]:
    """The relays' lifetimes per provider, as the roster labels them (state's
    labels, kept for machines gone from it): burnt and their median life, never
    burnt and how long so far, and how old their addresses were when their
    canaries first watched them (address_since). Nothing is looked up."""
    per: dict[str, dict] = {}
    for name in names:
        label = labels.get(name) or {}
        h = history(events, name, now)
        if not label.get("provider") or h["lasted"] is None:
            continue
        g = per.setdefault(label["provider"], {"ended": [], "going": [], "age": []})
        (g["going"] if h["lasting"] else g["ended"]).append(h["lasted"])
        if label.get("address_since"):
            since = calendar.timegm(time.strptime(label["address_since"], "%Y-%m-%d"))
            g["age"].append(h["watched"] - since)
    if not per:
        return []
    lines = ["", "by provider (the roster's provider), servers and relays: burnt and their median life, never burnt"]
    for name, g in sorted(per.items()):
        parts = [f"{len(g['ended'])} burnt" + (f", {span(statistics.median(g['ended']))} at the median" if g["ended"] else "")]
        if g["going"]:
            parts.append(f"{len(g['going'])} never burnt ({span(max(g['going']))} so far)")
        if g["age"]:
            parts.append(f"addresses {span(statistics.median(g['age']))} old when first watched, at the median")
        lines.append(f"{name:16} " + "; ".join(parts))
    return lines


def latency(net: Network, health: dict) -> list[str]:
    """Each server's and relay's latencies, the median of its kept readings
    per path, beside the canaries' own network leg (direct): the path's
    time less that is what the target, its upstream and the site add. A
    relay's path also shows what it adds over the servers' median on that
    path: the hop to the server, as near as canaries on different networks
    can tell. Machines with no latencies yet are left out."""
    def med(name: str, p: str) -> int | None:
        values = health.get(name, {}).get("latency", {}).get(p)
        return _median(values) if values else None

    servers = {p: [m for s in net.server if (m := med(s.name, p)) is not None] for p in PATHS}
    lines = []
    for m in [*net.server, *net.relay]:
        cells = []
        for p in PATHS:
            ms = med(m.name, p)
            if ms is None:
                continue
            hop = f" ({ms - _median(servers[p]):+d} over the servers)" if m.kind == "relay" and servers[p] else ""
            cells.append(f"{p} {ms}{hop}")
        if not cells:
            continue
        direct = med(m.name, "direct")
        lines.append(f"{m.name:12} network {'-' if direct is None else direct:>5}   " + ", ".join(cells))
    if not lines:
        return []
    return ["", "latency, ms (median of the last readings): the canaries' own network, then each path through it",
            *lines]


def report(net: Network, events: list, now: int, stands: dict | None = None,
           health: dict | None = None, labels: dict | None = None) -> list[str]:
    """The report's lines; stands, the spares standing in now (state's stands);
    health, the state's record per machine, for the paths and latencies;
    labels, the roster's provider and address_since per machine (state's)."""
    stands = stands or {}
    kinds = {m.name: ("spare" if getattr(m, "spare", False) else m.kind) for m in [*net.server, *net.relay]}
    rank = {"server": 0, "relay": 1, "spare": 2}
    names = sorted({e[1] for e in events} | set(kinds), key=lambda n: (rank.get(kinds.get(n, ""), 3), n))
    lines = [f"{'machine':12} {'kind':7} {'status':8} {'watched':10} {'lasted':>12} {'burns':>5} {'down':>8}  paths off"]
    relays = []
    for name in names:
        h = history(events, name, now)
        if h["watched"] is None and name not in kinds:
            continue
        kind = kinds.get(name, "gone")
        seen = h["watched"] is not None
        status = ("gone" if h["gone"] else "burnt" if h["burnt_now"] else "standing" if name in stands
                  else "waiting" if kind == "spare" else "up" if seen else "unseen")
        lasted = "-" if h["lasted"] is None else span(h["lasted"]) + ("+" if h["lasting"] else "")
        off = ", ".join(f"{p}×{n}" for p, n in sorted(h["off"].items())) or "-"
        stood = f"; stood in {h['stood']}×" if h["stood"] else ""
        lines.append(f"{name:12} {kind:7} {status:8} {day(h['watched']) if seen else '-':10} {lasted:>12} "
                     f"{len(h['burns']):>5} {span(h['down']) if h['burns'] else '-':>8}  {off}{stood}")
        if kind in ("relay", "spare", "gone") and h["lasted"] is not None:
            relays.append(h)
    ended = [h["lasted"] for h in relays if not h["lasting"]]
    going = [h["lasted"] for h in relays if h["lasting"]]
    month = sum(1 for e in events if e[2] == "burnt" and e[0] > now - 30 * 86400)
    waiting = sorted(n for n, k in kinds.items() if k == "spare" and n not in stands)
    lines.append("")
    lines.append(f"relays: {len(ended)} burnt, lasting {span(statistics.median(ended))} at the median"
                 if ended else "relays: none burnt yet")
    if going:
        watched = span(min(going)) if min(going) == max(going) else f"{span(min(going))} to {span(max(going))}"
        lines.append(f"        {len(going)} never burnt, watched {watched} so far")
    lines.append(f"        {month} burn(s) in the last 30 days; spares waiting: {', '.join(waiting) or 'none'}")
    return (lines + paths(names, events, now, health or {}) + providers(names, events, now, labels or {})
            + latency(net, health or {}))
