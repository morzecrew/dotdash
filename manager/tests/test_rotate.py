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
devices = ["phone"]
[[server]]
name = "a"
[[relay]]
name = "r1"
[[canary]]
name = "c1"
watches = "a"
[[canary]]
name = "c2"
watches = "r1"
"""
DAY = 86400
RELAY = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E"}


def test_a_rotation_from_start_to_finish():
    net = loads(ROSTER)
    st = state.load(Path("/nonexistent"), net)
    old = dict(st["keys"])
    server = lambda keys: {"domain": "a.example.net", "https_port": 443, "encryption": "E",
                           "public_key": state.public_key(keys["reality_key"])}
    facts = {"a": server(old), "r1": RELAY}
    with pytest.raises(Refused, match="start"):
        rotate.swap(st, net, facts, 0)

    # start: the next key second on the server, the canary watching it on the next key, the rest unchanged.
    rotate.start(st, 100)
    nxt = st["rotation"]["second"]
    assert nxt["reality_key"] != old["reality_key"] and st["keys"]["reality_key"] == old["reality_key"]
    docs, _ = render(net, st, facts)
    assert docs["a"]["parameters"]["reality_second_key"] == "true"
    assert docs["a"]["secrets"]["reality_key_second"] == nxt["reality_key"] and docs["a"]["secrets"]["reality_key"] == old["reality_key"]
    assert docs["c1"]["parameters"]["dotdash_public_key"] == state.public_key(nxt["reality_key"])
    assert docs["c1"]["secrets"]["dotdash_short_id"] == nxt["reality_short_id"]
    assert docs["r1"]["parameters"]["dotdash_public_key"] == state.public_key(old["reality_key"])
    assert docs["c2"]["parameters"]["dotdash_public_key"] == "P"  # a relay's canary: the relay's own key
    with pytest.raises(Refused, match="under way"):
        rotate.start(st, 101)

    # swap waits for c1 to get REALITY through on the next key, after start.
    stale = {"public_key": state.public_key(nxt["reality_key"]), "checked_at": 99, "paths": {"reality": True}}
    with pytest.raises(Refused, match="no canary"):
        rotate.swap(st, net, {**facts, "c1": stale}, 200)
    with pytest.raises(Refused, match="no canary"):
        rotate.swap(st, net, {**facts, "c1": {**stale, "checked_at": 150, "paths": {"reality": False}}}, 200)
    said = rotate.swap(st, net, {**facts, "c1": {**stale, "checked_at": 150}}, 200)
    assert "c1 got through" in said
    assert st["keys"]["reality_key"] == nxt["reality_key"] and st["rotation"]["second"]["reality_key"] == old["reality_key"]
    docs, _ = render(net, st, {**facts, "a": server(st["keys"])})
    assert docs["a"]["secrets"]["reality_key"] == nxt["reality_key"] and docs["a"]["secrets"]["reality_key_second"] == old["reality_key"]
    assert docs["r1"]["parameters"]["dotdash_public_key"] == state.public_key(nxt["reality_key"])
    assert docs["c1"]["parameters"]["dotdash_public_key"] == state.public_key(nxt["reality_key"])

    # finish: not before the window, unless forced; then the second key off.
    with pytest.raises(Refused, match="left on the old key"):
        rotate.finish(st, 200 + DAY)
    rotate.finish(st, 200 + rotate.WINDOW)
    docs, _ = render(net, st, {**facts, "a": server(st["keys"])})
    assert docs["a"]["parameters"]["reality_second_key"] == "false" and "reality_key_second" not in docs["a"]["secrets"]
    assert rotate.status(st, 0).startswith("no rotation")
    rotate.start(st, 300)  # and another may begin


def test_no_rotation_leaves_the_servers_as_they_were():
    net = loads(ROSTER)
    st = state.load(Path("/nonexistent"), net)
    facts = {"a": {"domain": "a.example.net", "https_port": 443, "encryption": "E",
                   "public_key": state.public_key(st["keys"]["reality_key"])}, "r1": RELAY}
    docs, _ = render(net, st, facts)
    assert "reality_second_key" not in docs["a"]["parameters"] and "reality_key_second" not in docs["a"]["secrets"]
    with pytest.raises(Refused, match="no rotation"):
        rotate.finish(st, 0)
    rotate.start(st, 0)
    assert rotate.swap(st, net, facts, 10, force=True).startswith("the new REALITY key is the servers' key (forced)")
