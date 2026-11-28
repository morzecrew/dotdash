"""The devices seen at several addresses at once, from the counts the
device-addresses profile puts in the relays' facts: a link passed around shows
as its device connected from three or more addresses at once on one relay, or
on two relays at once. A relay names a device <device>@<group> and counts the
addresses it is connected from right now, an IPv6 /64 as one; the relays' and
canaries' own ids are left out. Counts only, never an address."""

import time

DAYS = 30
# Addresses at once on one relay that name a device; a phone shows one or two.
MANY = 3
# Two relays' readings are at once within this: every machine refreshes its
# facts within 15 minutes past each hour (morzer's fleet timer).
WINDOW = 15 * 60
SAY = "if its link may have leaked, renew {} and sync"


def when(t: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(t))


def record(a: dict, facts: dict, now: int) -> list[str]:
    """A line for each device at MANY addresses or more on one relay, or on
    two relays whose readings are at once, kept DAYS for report. Only readings
    this sync is the first to see count: a relay's facts that stood in for a
    failed read, or did not refresh, said what they say once already."""
    read = {n: f["addresses"] for n, f in facts.items() if isinstance(f.get("addresses"), dict)}
    if not read:
        return []
    last, a["read"] = a.get("read", {}), {n: r["at"] for n, r in read.items()}
    new = {n for n, r in read.items() if last.get(n) != r["at"]}
    on: dict[str, dict[str, int]] = {}
    for n, r in read.items():
        for key, k in r["devices"].items():
            # A device's name holds no @, and is unique across groups.
            d = key.split("@")[0]
            if k > 0 and not d.startswith(("relay-", "canary-")):
                on.setdefault(d, {})[n] = k
    lines = []
    for d, by in sorted(on.items()):
        lines += [f"{d}: {by[n]} addresses at once on relay {n} at {when(read[n]['at'])}: {SAY.format(d)}"
                  for n in sorted(new & set(by)) if by[n] >= MANY]
        # Counts can't tell one address from two, so an app that keeps two
        # relays open from one address shows here too: the price of counts.
        both = sorted({n for n in by for m in by
                       if m != n and new & {n, m} and abs(read[n]["at"] - read[m]["at"]) <= WINDOW})
        if both:
            lines.append(f"{d}: on relays {', '.join(both)} at once at {when(max(read[n]['at'] for n in both))}:"
                         f" {SAY.format(d)}")
    kept = a.setdefault("seen", [])
    kept += [{"at": now, "line": line} for line in lines]
    kept[:] = [s for s in kept if s["at"] > now - DAYS * 86400]
    return lines


def seen(a: dict, since: int = 0) -> list[str]:
    """The lines record kept, from since on."""
    return [s["line"] for s in a.get("seen", []) if s["at"] >= since]
