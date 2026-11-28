from pathlib import Path

import pytest

from dotdash_manager import Refused, rotate, state
from dotdash_manager.render import render
from dotdash_manager.roster import loads

ROSTER = """
target = "t"
key = "k"
identity = "i"
authority = "a"
[[group]]
name = "g"
devices = ["phone"]
[[group]]
name = "h"
[[server]]
name = "a"
group = "g"
[[server]]
name = "b"
group = "h"
[[relay]]
name = "r1"
[[canary]]
name = "c1"
watches = "a"
[[canary]]
name = "c2"
watches = "r1"
[[canary]]
name = "c3"
watches = "b"
"""
DAY = 86400
RELAY = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "name": "r1", "nonce": "0123456789abcdef"}


def test_a_rotation_from_start_to_finish():
    """Every group at once, each to a next key of its own, each proven by a
    canary watching one of its servers."""
    net = loads(ROSTER)
    st = state.load(Path("/nonexistent"), net)
    old = {g: dict(st["keys"][g]) for g in ("g", "h")}
    server = lambda name, keys: {"domain": f"{name}.example.net", "https_port": 443, "encryption": "E",
                                 "public_key": state.public_key(keys["reality_key"])}
    facts = {"a": server("a", old["g"]), "b": server("b", old["h"]), "r1": RELAY}
    with pytest.raises(Refused, match="start"):
        rotate.swap(st, net, facts, 0)

    # start: the next key second on the server, the canary watching it on the next key, the rest unchanged.
    rotate.start(st, net, 100)
    nxt = st["rotation"]["second"]
    assert nxt["g"]["reality_key"] != old["g"]["reality_key"] != nxt["h"]["reality_key"]
    assert st["keys"]["g"]["reality_key"] == old["g"]["reality_key"]
    docs, _ = render(net, st, facts)
    assert docs["a"]["parameters"]["reality_second_key"] == "true"
    assert docs["a"]["secrets"]["reality_key_second"] == nxt["g"]["reality_key"]
    assert docs["a"]["secrets"]["reality_key"] == old["g"]["reality_key"]
    assert docs["b"]["secrets"]["reality_key_second"] == nxt["h"]["reality_key"]
    assert docs["c1"]["parameters"]["dotdash_public_key"] == state.public_key(nxt["g"]["reality_key"])
    assert docs["c1"]["secrets"]["dotdash_short_id"] == nxt["g"]["reality_short_id"]
    assert state.public_key(old["g"]["reality_key"]) in docs["r1"]["secrets"]["servers"]
    assert docs["c2"]["parameters"]["dotdash_public_key"] == "P"  # a relay's canary: the relay's own key
    with pytest.raises(Refused, match="under way"):
        rotate.start(st, net, 101)

    # swap waits for c1 to get REALITY through on the next key, after start.
    proof = lambda g, at=150, up=True: {"public_key": state.public_key(nxt[g]["reality_key"]), "checked_at": at,
                                        "paths": {"reality": up}}
    with pytest.raises(Refused, match="no canary watching a server of g, h"):
        rotate.swap(st, net, {**facts, "c1": proof("g", at=99)}, 200)
    with pytest.raises(Refused, match="no canary watching a server of g, h"):
        rotate.swap(st, net, {**facts, "c1": proof("g", up=False)}, 200)
    # One group's canary proves that group's key alone.
    with pytest.raises(Refused, match="no canary watching a server of h has"):
        rotate.swap(st, net, {**facts, "c1": proof("g"), "c3": proof("g")}, 200)
    said = rotate.swap(st, net, {**facts, "c1": proof("g"), "c3": proof("h")}, 200)
    assert "c1, c3 got through" in said
    assert st["keys"]["g"]["reality_key"] == nxt["g"]["reality_key"]
    assert st["rotation"]["second"]["g"]["reality_key"] == old["g"]["reality_key"]
    facts = {**facts, "a": server("a", st["keys"]["g"]), "b": server("b", st["keys"]["h"])}
    docs, _ = render(net, st, facts)
    assert docs["a"]["secrets"]["reality_key"] == nxt["g"]["reality_key"]
    assert docs["a"]["secrets"]["reality_key_second"] == old["g"]["reality_key"]
    assert state.public_key(nxt["g"]["reality_key"]) in docs["r1"]["secrets"]["servers"]
    assert docs["c1"]["parameters"]["dotdash_public_key"] == state.public_key(nxt["g"]["reality_key"])

    # finish: not before the window, unless forced; then the second key off.
    with pytest.raises(Refused, match="left on the old key"):
        rotate.finish(st, 200 + DAY)
    rotate.finish(st, 200 + rotate.WINDOW)
    docs, _ = render(net, st, facts)
    assert docs["a"]["parameters"]["reality_second_key"] == "false" and "reality_key_second" not in docs["a"]["secrets"]
    # The old key leaves the server's secret store, beside the pools and flags it has none of.
    assert docs["a"]["unset"] == {"parameters": ["relay_flags", "pools"],
                                  "secrets": ["reality_key_second", "reality_short_id_second"]}
    assert rotate.status(st, 0).startswith("no rotation")
    rotate.start(st, net, 300)  # and another may begin


def test_no_rotation_leaves_the_servers_as_they_were():
    net = loads(ROSTER)
    st = state.load(Path("/nonexistent"), net)
    facts = {"a": {"domain": "a.example.net", "https_port": 443, "encryption": "E",
                   "public_key": state.public_key(st["keys"]["g"]["reality_key"])}, "r1": RELAY}
    docs, _ = render(net, st, facts)
    assert "reality_second_key" not in docs["a"]["parameters"] and "reality_key_second" not in docs["a"]["secrets"]
    assert "secrets" not in docs["a"].get("unset", {})
    with pytest.raises(Refused, match="no rotation"):
        rotate.finish(st, 0)
    rotate.start(st, net, 0)
    assert rotate.swap(st, net, facts, 10, force=True).startswith("the new REALITY key is the servers' key (forced)")
