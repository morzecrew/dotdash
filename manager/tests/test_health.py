from pathlib import Path

from dotdash_manager import state
from dotdash_manager.health import BURN_AFTER, judge
from dotdash_manager.render import render
from dotdash_manager.roster import loads

ROSTER = """
target = "file:///tmp/t"
key = "a.key"
identity = "a.age"
authority = "RWQ"
devices = ["phone"]
pools = { a = ["phone", "203.0.113.5", "c.example.net"], b = ["203.0.113.5"] }
[[server]]
name = "s"
[[relay]]
name = "r1"
[[relay]]
name = "r2"
[[canary]]
name = "c1"
watches = "r1"
[[canary]]
name = "c2"
watches = "r2"
"""
R1 = {"entry_host": "203.0.113.5", "site": "one.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
      "cdn_hosts": ["c.example.net"]}
R2 = {**R1, "entry_host": "203.0.113.6", "site": "two.example.net", "cdn_hosts": []}


def canary(relay: dict, at: int, up: bool, internet: bool | None = True) -> dict:
    return {"server": relay["site"], "address": relay["entry_host"], "checked_at": at, "internet": internet,
            "paths": {"reality": up, "xhttp": False}}


def run(net, health, at, c1_up=False, c2_up=True, **c1):
    facts = {"r1": R1, "r2": R2, "c1": canary(R1, at, c1_up, **c1), "c2": canary(R2, at, c2_up)}
    return judge(net, facts, health)


def test_a_relay_is_burnt_after_its_readings_in_a_row_fail_and_back_once_one_gets_through():
    net, health = loads(ROSTER), {}
    for at in range(1, BURN_AFTER):
        assert run(net, health, at)[0] == set()
    burnt, say = run(net, health, BURN_AFTER)
    assert burnt == {"r1"} and health["r1"]["since"] == 1
    assert any(line.startswith("burnt: relay r1:") for line in say)
    # One path through, from one reading, and it is back.
    assert run(net, health, BURN_AFTER + 1, c1_up=True)[0] == set()
    assert health["r1"] == {"fails": 0, "at": BURN_AFTER + 1}


def test_a_reading_counts_once_and_an_offline_canary_or_stale_target_not_at_all():
    net, health = loads(ROSTER), {}
    for _ in range(BURN_AFTER):
        run(net, health, 7)
    assert health["r1"]["fails"] == 1
    for at in range(8, 8 + BURN_AFTER):
        run(net, health, at, internet=False)
    assert health["r1"]["fails"] == 1
    moved = {"r1": R1, "r2": R2, "c1": canary(R2, 99, False), "c2": canary(R2, 99, True)}
    judge(net, moved, health)
    assert health["r1"]["fails"] == 1


def test_every_relay_failing_at_once_drops_none():
    net, health = loads(ROSTER), {}
    for at in range(1, BURN_AFTER):
        run(net, health, at, c2_up=False)
    burnt, say = run(net, health, BURN_AFTER, c2_up=False)
    assert burnt == set() and "check the canaries' network" in say[-1]


def test_a_burnt_relay_leaves_the_servers_relays_and_pools():
    net = loads(ROSTER)
    st = state.load(Path("/nonexistent"), net)
    facts = {"s": {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
                   "encryption": "E"}, "r1": R1, "r2": R2}
    params = render(net, st, facts, {"r1"})[0]["s"]["parameters"]
    assert params["relays"] == "203.0.113.6 two.example.net P S E"
    assert params["pools"] == "a phone"
    docs = render(net, st, facts)[0]
    assert docs["s"]["parameters"]["pools"] == "a phone 203.0.113.5 c.example.net\nb 203.0.113.5"
