"""What the manager's event log (health.events) says of each server and relay:
since when its canaries watch it, how long it lasted before it first burnt,
how often it burnt and for how long, which of its paths went off, how often
a spare stood in; and across the relays, how long one lasts. Machines gone
from the roster stay in it: how long a replaced relay lasted is the point.
Then where the time goes, from the canaries' latencies (health.record).
Pure: it reads nothing and writes nothing."""

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
    h = {"watched": None, "burns": [], "gone": None, "off": Counter(), "stood": 0}
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
           health: dict | None = None) -> list[str]:
    """The report's lines; stands, the spares standing in now (state's stands);
    health, the state's record per machine, for the latencies."""
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
    return lines + latency(net, health or {})
