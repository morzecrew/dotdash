from pathlib import Path

from dotdash_manager import state
from dotdash_manager.health import BURN_AFTER, blocked, judge
from dotdash_manager.render import relay_line, render
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
    assert health["r1"]["fails"] == 0 and health["r1"]["at"] == BURN_AFTER + 1 and "since" not in health["r1"]


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


def test_a_cdn_only_relay_carries_the_flag_is_never_judged_and_serves_no_subscription():
    net, health = loads(ROSTER), {"r1": {"fails": BURN_AFTER, "at": 1}}
    only = {**R1, "cdn_only": True, "own_site": {"xhttp_path": "p"}}
    facts = {"r1": only, "r2": R2, "c1": canary(R1, 5, False), "c2": canary(R2, 5, True)}
    assert judge(net, facts, health)[0] == set() and "r1" not in health
    assert relay_line(only).endswith(" cdn=c.example.net cdn-only")


def paths_run(net, health, at, r1: dict, r2: dict):
    c = lambda relay, paths: {"server": relay["site"], "address": relay["entry_host"], "checked_at": at,
                              "internet": True, "paths": paths}
    facts = {"r1": R1, "r2": R2, "c1": c(R1, r1), "c2": c(R2, r2)}
    burnt, _ = judge(net, facts, health)
    return facts, blocked(net, facts, health, burnt)


def test_a_path_blocked_on_one_relay_goes_off_its_line_and_comes_back():
    net, health = loads(ROSTER), {}
    for at in range(1, BURN_AFTER + 1):
        facts, (off, say) = paths_run(net, health, at, {"reality": False, "xhttp": True}, {"reality": True, "xhttp": True})
    assert off == {"r1": {"reality"}} and any(line.startswith("blocked: relay r1: reality") for line in say)
    st = state.load(Path("/nonexistent"), net)
    facts["s"] = {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
                  "encryption": "E"}
    relays = render(net, st, facts, set(), off)[0]["s"]["parameters"]["relays"].splitlines()
    assert relays[0].endswith(" cdn=c.example.net off=reality") and "off=" not in relays[1]
    # One reading through, and the path is back.
    _, (off, _) = paths_run(net, health, BURN_AFTER + 1, {"reality": True, "xhttp": True}, {"reality": True, "xhttp": True})
    assert off == {}


def test_a_path_blocked_on_every_relay_stays_and_every_path_blocked_burns_instead():
    net, health = loads(ROSTER), {}
    for at in range(1, BURN_AFTER + 1):
        _, (off, say) = paths_run(net, health, at, {"reality": False, "xhttp": True}, {"reality": False, "xhttp": True})
    assert off == {} and "check whether the canaries' network blocks reality" in say[0]
    health = {}
    for at in range(1, BURN_AFTER + 1):
        _, (off, _) = paths_run(net, health, at, {"reality": False, "xhttp": False}, {"reality": True, "xhttp": True})
    assert off == {} and health["r1"]["fails"] == BURN_AFTER
