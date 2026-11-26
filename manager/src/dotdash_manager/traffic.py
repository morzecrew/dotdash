"""Each device's bytes a day, from the counts the device-traffic profile puts in
the servers' and relays' facts, and the days a device moved far more than it
usually does: a link passed around shows as its device moving much more than
it ever did. A device behind a relay reaches the server under the relay's id,
so the relay counts it and the server counts the relay; the relays' and
canaries' own ids are left out. Counts only, never an address."""

import statistics
import time

DAYS = 30
# A day is unusual at TIMES its device's median of the days before, and at
# least FLOOR bytes, once there are MIN_DAYS days before it to judge by.
TIMES = 5
FLOOR = 2 * 10**9
MIN_DAYS = 7


def day(t: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(t))


def record(t: dict, facts: dict, now: int) -> None:
    """Adds to today what each machine's counters moved since the last read.
    A machine's first counts only set where it starts: what came before them,
    and since when, is unknown. A counter that started again (Xray restarted:
    its started moved) counts from zero. Nothing without counts in any facts."""
    counted = {n: f["traffic"] for n, f in facts.items()
               if isinstance(f.get("traffic"), dict) and isinstance(f["traffic"].get("devices"), dict)}
    if not counted:
        return
    last = t.setdefault("counters", {})
    days = t.setdefault("days", {})
    today = days.setdefault(day(now), {})
    for name, c in counted.items():
        prev, last[name] = last.get(name), c
        if prev is None:
            continue
        again = abs(c.get("started", 0) - prev.get("started", 0)) > 60
        for d, n in c["devices"].items():
            if d.startswith(("relay-", "canary-")):
                continue
            moved = n if again else n - prev["devices"].get(d, 0)
            if moved > 0:
                today[d] = today.get(d, 0) + moved
    for old in sorted(days)[:-DAYS]:
        del days[old]


def unusual(t: dict, since: str = "") -> list[str]:
    """A line for each device and day, from since on, far above that device's
    median of the days before it (a day it moved nothing counts as 0)."""
    days = t.get("days", {})
    order = sorted(days)
    lines = []
    for i, d in enumerate(order):
        if d < since or i < MIN_DAYS:
            continue
        for dev, n in sorted(days[d].items()):
            usual = statistics.median(days[p].get(dev, 0) for p in order[:i])
            if n >= FLOOR and n >= TIMES * usual:
                lines.append(f"{dev}: {n / 1e9:.1f} GB on {d}, against {usual / 1e9:.1f} GB on its usual day:"
                             f" if its link may have leaked, renew {dev} and sync")
    return lines

