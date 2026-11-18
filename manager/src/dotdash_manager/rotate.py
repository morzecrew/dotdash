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

State keeps where it stands, as rotation = {phase, since, second}: phase
"next" or "swapped" with the second key set, "done" after finish. Pure but
for the clock it is handed."""

from . import Refused
from .roster import Network
from .state import SHARED_KEYS, public_key

WINDOW = 7 * 86400
KEYS = ("reality_key", "reality_short_id")


def phase(state: dict) -> str:
    return state.get("rotation", {}).get("phase", "none")


def second(state: dict) -> dict | None:
    """The second key set the servers get, or None with no rotation under way."""
    r = state.get("rotation", {})
    return r.get("second") if r.get("phase") in ("next", "swapped") else None


def canary_key(state: dict) -> dict | None:
    """The key set the canaries watching servers check them under, when it is
    not the current one: the next key, between start and swap."""
    r = state.get("rotation", {})
    return r["second"] if r.get("phase") == "next" else None


def start(state: dict, now: int) -> str:
    if phase(state) in ("next", "swapped"):
        raise Refused(f"a rotation is under way ({phase(state)}): swap or finish it first")
    state["rotation"] = {"phase": "next", "since": now, "second": {k: SHARED_KEYS[k]() for k in KEYS}}
    return ("the next REALITY key goes to the servers as their second, and the canaries watching them move to it; "
            "once one gets through on it, run rotate swap")


def proven(net: Network, facts: dict, state: dict) -> list[str]:
    """The canaries watching servers that got REALITY through on the next key
    since start: facts naming it, a reading after start, reality up."""
    r = state["rotation"]
    pbk = public_key(r["second"]["reality_key"])
    servers = {s.name for s in net.server}
    return [c.name for c in net.canary if c.watches in servers and (f := facts.get(c.name))
            and f.get("public_key") == pbk and isinstance(f.get("checked_at"), int)
            and f["checked_at"] >= r["since"] and (f.get("paths") or {}).get("reality") is True]


def swap(state: dict, net: Network, facts: dict, now: int, force: bool = False) -> str:
    if phase(state) != "next":
        raise Refused("nothing to swap: run rotate start first" if phase(state) in ("none", "done")
                      else "already swapped: rotate finish retires the old key")
    ok = proven(net, facts, state)
    if not ok and not force:
        raise Refused("no canary watching a server has got REALITY through on the next key yet "
                      "(a canary's facts name the key it checks under from this release on): wait for a sync after it applied, "
                      "or --force")
    keys = state["keys"]
    old = {k: keys[k] for k in KEYS}
    keys.update(state["rotation"]["second"])
    state["rotation"] = {"phase": "swapped", "since": now, "second": old}
    by = f"{', '.join(ok)} got through on it" if ok else "forced"
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
