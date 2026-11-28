"""Rotating the REALITY key with no device cut off, over the servers'
reality_second_key (a second key beside reality_key, devices holding either
let in). Three steps, each published by the next sync:

  start   a next key, second on the servers; the canaries watching servers
          move to it, while devices and relays keep the current key;
  swap    once a canary got REALITY through on the next key, it becomes the
          key and the old one second: subscriptions and relays move to the new
          key, and devices still on the old one keep getting in;
  finish  after WINDOW, so every device had a subscription refresh or new
          links, the second key goes off.

Every server group rotates at once, each to a next key of its own. State
keeps where it stands, as rotation = {phase, since, second}: phase "next" or
"swapped" with second each group's second key set, "done" after finish. Pure
but for the clock it is handed."""

from . import Refused
from .roster import Network
from .state import SHARED_KEYS, public_key

WINDOW = 7 * 86400
KEYS = ("reality_key", "reality_short_id")


def phase(state: dict) -> str:
    return state.get("rotation", {}).get("phase", "none")


def second(state: dict, group: str) -> dict | None:
    """The second key set a group's servers get, or None with no rotation
    under way for it."""
    r = state.get("rotation", {})
    return r["second"].get(group) if r.get("phase") in ("next", "swapped") else None


def canary_key(state: dict, group: str) -> dict | None:
    """The key set the canaries watching a group's servers check them under,
    when it is not the current one: the next key, between start and swap."""
    r = state.get("rotation", {})
    return r["second"].get(group) if r.get("phase") == "next" else None


def start(state: dict, net: Network, now: int) -> str:
    if phase(state) in ("next", "swapped"):
        raise Refused(f"a rotation is under way ({phase(state)}): swap or finish it first")
    state["rotation"] = {"phase": "next", "since": now,
                         "second": {g.name: {k: SHARED_KEYS[k]() for k in KEYS} for g in net.group}}
    return ("each group's next REALITY key goes to its servers as their second, and the canaries watching them move "
            "to it; once one per group gets through on it, run rotate swap")


def proven(net: Network, facts: dict, state: dict) -> dict[str, list[str]]:
    """The canaries watching each group's servers that got REALITY through on
    its next key since start: facts naming it, a reading after start, reality up."""
    r = state["rotation"]
    out: dict[str, list[str]] = {}
    for c in net.canary:
        target, f = net.find(c.watches), facts.get(c.name)
        nxt = r["second"].get(net.group_of(target)) if target.kind == "server" else None
        if (nxt and f and f.get("public_key") == public_key(nxt["reality_key"]) and isinstance(f.get("checked_at"), int)
                and f["checked_at"] >= r["since"] and (f.get("paths") or {}).get("reality") is True):
            out.setdefault(net.group_of(target), []).append(c.name)
    return out


def swap(state: dict, net: Network, facts: dict, now: int, force: bool = False) -> str:
    if phase(state) != "next":
        raise Refused("nothing to swap: run rotate start first" if phase(state) in ("none", "done")
                      else "already swapped: rotate finish retires the old key")
    ok = proven(net, facts, state)
    lacking = [g for g in state["rotation"]["second"] if g not in ok and net.servers_of(g)]
    if lacking and not force:
        raise Refused(f"no canary watching a server of {', '.join(lacking)} has got REALITY through on its next key yet "
                      "(a canary's facts name the key it checks under from this release on): wait for a sync after it applied, "
                      "or --force")
    old = {}
    for g, nxt in state["rotation"]["second"].items():
        old[g] = {k: state["keys"][g][k] for k in KEYS}
        state["keys"][g].update(nxt)
    state["rotation"] = {"phase": "swapped", "since": now, "second": old}
    names = [c for cs in ok.values() for c in cs]
    by = f"{', '.join(names)} got through on it" if names and not lacking else "forced"
    return (f"the new REALITY key is the servers' key ({by}), the old one their second: subscriptions and relays move "
            f"to the new key, devices on the old one keep getting in; rotate finish after {WINDOW // 86400} days")


def finish(state: dict, now: int, force: bool = False) -> str:
    if phase(state) != "swapped":
        raise Refused("nothing to finish: rotate swap comes first" if phase(state) == "next" else "no rotation under way")
    left = state["rotation"]["since"] + WINDOW - now
    if left > 0 and not force:
        raise Refused(f"devices have {left // 3600}h left on the old key; wait, or --force once every device has the new links")
    state["rotation"] = {"phase": "done", "since": now}
    return "the old REALITY key goes off on the servers: only the new one gets in"


def status(state: dict, now: int) -> str:
    r = state.get("rotation", {})
    p = phase(state)
    if p in ("none", "done"):
        return "no rotation under way; rotate start begins one"
    days = (now - r["since"]) // 86400
    if p == "next":
        return f"next key second on the servers for {days}d; rotate swap once a canary gets through on it"
    return f"swapped {days}d ago, the old key second; rotate finish after {WINDOW // 86400} days"
