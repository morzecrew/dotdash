from pathlib import Path

from dotdash_manager import state
from dotdash_manager.health import BURN_AFTER, CAUSES, FRESH, alive, blocked, judge, spares
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


def test_a_quiet_canarys_old_success_does_not_hold_a_relay_up():
    net = loads(ROSTER.replace('name = "c2"\nwatches = "r2"', 'name = "c2"\nwatches = "r1"')
                + '[[canary]]\nname = "c3"\nwatches = "r2"\n')
    health, old = {}, 1000
    for n in range(1, BURN_AFTER + 1):
        # c1 fails every hour; c2 got through once, three hours back, and went quiet.
        now = old + 3 * 3600 + n * 3600
        facts = {"r1": R1, "r2": R2, "c1": canary(R1, now, False), "c2": canary(R1, old, True),
                 "c3": canary(R2, now, True)}
        burnt, _ = judge(net, facts, health)
    assert burnt == {"r1"} and health["r1"]["fails"] == BURN_AFTER
    # Two canaries an hour apart, as their schedules fall, both count.
    health = {}
    facts = {"r1": R1, "r2": R2, "c1": canary(R1, old + FRESH, False), "c2": canary(R1, old + FRESH - 3600, True),
             "c3": canary(R2, old, True)}
    judge(net, facts, health)
    assert health["r1"]["fails"] == 0


def test_a_canary_whose_clock_runs_ahead_neither_burns_a_relay_nor_holds_it():
    net = loads(ROSTER.replace('name = "c2"\nwatches = "r2"', 'name = "c2"\nwatches = "r1"')
                + '[[canary]]\nname = "c3"\nwatches = "r2"\n')
    health, now = {}, 10_000
    for n in range(BURN_AFTER + 1):
        # c2 says it read a year on, failing; c1, on time, gets through.
        facts = {"r1": R1, "r2": R2, "c1": canary(R1, now + n * 3600, True), "c2": canary(R1, now + 365 * 86400, False),
                 "c3": canary(R2, now + n * 3600, True)}
        burnt, _ = judge(net, facts, health, None, now + n * 3600)
    assert burnt == set() and health["r1"]["fails"] == 0 and health["r1"]["at"] == now + BURN_AFTER * 3600
    # A few minutes ahead still counts.
    facts["c1"] = canary(R1, now + BURN_AFTER * 3600 + 900, False)
    judge(net, facts, health, None, now + BURN_AFTER * 3600 + 400)
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


def test_a_burnt_relays_door_names_leave_the_pools_too():
    net = loads(ROSTER.replace('"c.example.net"]', '"c.example.net", "o.example.ru", "alt.example.ru"]'))
    st = state.load(Path("/nonexistent"), net)
    r1 = {**R1, "cdn_path": "y", "origin_host": "o.example.ru,alt.example.ru"}
    facts = {"s": {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
                   "encryption": "E"}, "r1": r1, "r2": R2}
    assert render(net, st, facts, {"r1"})[0]["s"]["parameters"]["pools"] == "a phone"


def test_a_burnt_or_held_relay_claiming_anothers_host_moves_it_in_no_pool():
    net = loads(SPARES)
    st = state.load(Path("/nonexistent"), net)
    server = {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
              "encryption": "E"}
    # r2 burnt and r3, a spare held back, both name r1's address and CDN host.
    liar = {**R2, "cdn_hosts": ["c.example.net"], "origin_host": "203.0.113.5"}
    facts = {"s": server, "r1": R1, "r2": liar, "r3": {**R3, "entry_host": "203.0.113.5"}, "r4": R4}
    docs, waiting = render(net, st, facts, {"r2", "r3", "r4"})
    assert docs["s"]["parameters"]["pools"] == "a phone 203.0.113.5 c.example.net\nb 203.0.113.5"
    assert "203.0.113.5: more than one relay's facts name it, so no burnt relay or spare moves it in the pools" in waiting
    # Nor does a spare standing in for it carry its own hosts into r1's pools.
    docs, _ = render(net, st, facts, {"r2", "r3"}, None, {"r4": "r2"})
    assert docs["s"]["parameters"]["pools"] == "a phone 203.0.113.5 c.example.net\nb 203.0.113.5"


def test_a_cdn_only_relay_carries_the_flag_and_is_not_judged_until_a_canary_checks_its_cdns():
    net, health = loads(ROSTER), {"r1": {"fails": BURN_AFTER, "at": 1}}
    only = {**R1, "cdn_only": True, "own_site": {"xhttp_path": "p"}}
    facts = {"r1": only, "r2": R2, "c1": canary(R1, 5, False), "c2": canary(R2, 5, True)}
    assert judge(net, facts, health)[0] == set() and "r1" not in health
    # A canary's release that checks CDNs, given none of r1's yet.
    facts["c1"] = {**canary(R1, 6, False), "cdn": {}}
    assert judge(net, facts, health)[0] == set() and "r1" not in health
    assert relay_line(only).endswith(" cdn=c.example.net cdn-only")


def test_a_cdn_only_relay_is_judged_by_its_cdns_alone():
    net, health = loads(ROSTER), {}
    only = {**R1, "cdn_only": True, "cdn_path": "y", "origin_host": "o.example.ru/g"}

    def run_cdn(at: int, cdn: dict, c2_up: bool = True):
        # Its own address, which no device gets: REALITY down but split, an
        # address block, a latency. None of it counts.
        c1 = {**canary(R1, at, False), "cdn": cdn, "reality_split": True, "blocked_by": "ip", "latency_ms": {"xhttp": 50}}
        facts = {"r1": only, "r2": R2, "c1": c1, "c2": canary(R2, at, c2_up)}
        burnt, say = judge(net, facts, health)
        return burnt, say, blocked(net, facts, health, burnt)

    # A name r1 no longer gives counts for nothing.
    for at in range(1, BURN_AFTER + 1):
        burnt, say, _ = run_cdn(at, {"c.example.net": False, "o.example.ru": False, "gone.example.net": True})
    assert burnt == {"r1"} and any(line.startswith("burnt: relay r1:") for line in say)
    assert health["r1"]["paths"] == {"cdn:c.example.net": BURN_AFTER, "cdn:o.example.ru": BURN_AFTER}
    assert not {"cause", "split", "latency"} & set(health["r1"])
    # One CDN through, and it is back; the other, still out, goes off its line alone.
    for at in range(BURN_AFTER + 1, 2 * BURN_AFTER + 1):
        burnt, _, (off, say) = run_cdn(at, {"c.example.net": True, "o.example.ru": False})
    assert burnt == set() and off == {"r1": {"cdn:o.example.ru"}} and health["r1"]["fails"] == 0
    assert any(line.startswith("blocked: relay r1: cdn:o.example.ru got through") for line in say)
    # Every relay at once, a cdn-only one among them, is kept.
    for at in range(2 * BURN_AFTER + 1, 3 * BURN_AFTER + 1):
        burnt, say, _ = run_cdn(at, {"c.example.net": False, "o.example.ru": False}, c2_up=False)
    assert burnt == set() and "check the canaries' network" in say[-1]


def test_a_relays_cdn_holds_it_up_and_goes_off_alone():
    net, health = loads(ROSTER), {}

    def run_cdn(at: int, paths: dict, cdn: dict):
        c = lambda relay, p: {"server": relay["site"], "address": relay["entry_host"], "checked_at": at,
                              "internet": True, "paths": p}
        facts = {"r1": {**R1, "cdn_path": "y"}, "r2": R2, "c1": {**c(R1, paths), "cdn": cdn},
                 "c2": c(R2, {"reality": True, "xhttp": True})}
        burnt, _ = judge(net, facts, health)
        return burnt, blocked(net, facts, health, burnt)

    # Its own address blocked, its CDN through: devices keep the CDN links.
    for at in range(1, BURN_AFTER + 1):
        burnt, (off, _) = run_cdn(at, {"reality": False, "xhttp": False}, {"c.example.net": True})
    assert burnt == set() and off == {"r1": {"reality", "xhttp"}}
    health = {}
    for at in range(1, BURN_AFTER + 1):
        burnt, (off, say) = run_cdn(at, {"reality": True, "xhttp": True}, {"c.example.net": False})
    assert burnt == set() and off == {"r1": {"cdn:c.example.net"}}
    assert any(line.startswith("blocked: relay r1: cdn:c.example.net got through for none") for line in say)


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


def row(age="40m", stale=False, services=5, running=5, problem=""):
    return {"age": age, "stale": stale, "services": services, "running": running, "problem": problem}


def test_a_machines_own_row_says_blocked_or_down():
    assert alive(None) == ("", "")
    assert alive(row())[0] == "blocked"
    assert alive(row(stale=True, age="5h"))[0] == "down"
    assert alive(row(running=3))[0] == "down" and "3 of 5" in alive(row(running=3))[1]
    assert alive(row(services=None, running=None, problem="docker refused"))[0] == "down"
    assert alive(row(services=None, running=None))[0] == "blocked"


def test_a_burnt_relay_running_is_blocked_and_replaced_one_down_is_fixed():
    net = loads(ROSTER)
    for rows, has, lacks in (({"r1": row()}, ["blocked on the way", "replace it"], ["fix it"]),
                             ({"r1": row(running=2)}, ["2 of 5", "fix it first"], ["replace it"]),
                             ({}, ["replace it"], ["own fleet row"])):
        health = {}
        for at in range(1, BURN_AFTER + 1):
            facts = {"r1": R1, "r2": R2, "c1": canary(R1, at, False), "c2": canary(R2, at, True)}
            burnt, say = judge(net, facts, health, rows)
        line = next(x for x in say if x.startswith("burnt: relay r1:"))
        assert burnt == {"r1"} and all(h in line for h in has) and not any(x in line for x in lacks), line


SPARES = ROSTER + """
[[relay]]
name = "r3"
spare = true
[[relay]]
name = "r4"
spare = true
[[canary]]
name = "c4"
watches = "r4"
"""
R3 = {**R1, "entry_host": "203.0.113.7", "site": "three.example.net", "cdn_hosts": []}
R4 = {**R1, "entry_host": "203.0.113.8", "site": "four.example.net", "cdn_hosts": ["d.example.net"]}


def spare_run(net, health, at, r1_up=False, r4_up=True):
    facts = {"r1": R1, "r2": R2, "r3": R3, "r4": R4, "c1": canary(R1, at, r1_up), "c2": canary(R2, at, True),
             "c4": canary(R4, at, r4_up)}
    burnt, _ = judge(net, facts, health)
    return facts, burnt, spares(net, facts, health, burnt)


def test_spares_wait_out_of_sight_then_the_watched_one_stands_in_for_a_burnt_relay():
    net, health = loads(SPARES), {}
    st = state.load(Path("/nonexistent"), net)
    server = {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
              "encryption": "E"}
    facts, burnt, (held, stands, say) = spare_run(net, health, 1)
    assert burnt == set() and held == {"r3", "r4"} and stands == {} and say == []
    params = render(net, st, {**facts, "s": server}, burnt | held, None, stands)[0]["s"]["parameters"]
    assert "203.0.113.7" not in params["relays"] and "203.0.113.8" not in params["relays"]
    for at in range(2, BURN_AFTER + 1):
        facts, burnt, (held, stands, say) = spare_run(net, health, at)
    # r4, which its canary got through to, before r3, which none watches.
    assert burnt == {"r1"} and stands == {"r4": "r1"} and held == {"r3"}
    assert say[0].startswith("spare: r4 stands in for burnt relay r1") and "check it" not in say[0]
    docs = render(net, st, {**facts, "s": server}, burnt | held, None, stands)[0]
    params = docs["s"]["parameters"]
    assert "203.0.113.8 four.example.net" in params["relays"] and "203.0.113.5" not in params["relays"]
    assert params["pools"] == "a phone 203.0.113.8 d.example.net\nb 203.0.113.8 d.example.net"
    assert "r4" in docs and "c4" in docs
    # r1 back: r4 waits again.
    facts, burnt, (held, stands, say) = spare_run(net, health, BURN_AFTER + 1, r1_up=True)
    assert burnt == set() and stands == {} and held == {"r3", "r4"}


def test_a_burnt_spare_stands_in_for_nothing_and_none_left_is_said():
    net, health = loads(SPARES), {}
    for at in range(1, BURN_AFTER + 1):
        facts, burnt, (held, stands, say) = spare_run(net, health, at, r4_up=False)
    assert burnt == {"r1", "r4"} and stands == {"r3": "r1"} and held == set()
    assert "no canary has got through to it yet" in say[0]
    two = loads(SPARES.replace('name = "r3"\nspare = true\n', 'name = "r3"\n'))
    health = {}
    for at in range(1, BURN_AFTER + 1):
        facts, burnt, (held, stands, say) = spare_run(two, health, at, r4_up=False)
    assert stands == {} and say == ["spare: none left for burnt relay r1; add a relay with spare = true, or replace r1"]
    # A cdn-only spare never stands in, and never shows either.
    net, health = loads(SPARES), {}
    facts = {"r1": R1, "r2": R2, "r3": {**R3, "cdn_only": True}, "r4": R4}
    assert spares(net, facts, health, set())[0] == {"r3", "r4"}


def test_a_server_blocked_by_sni_gets_its_hello_split():
    from pathlib import Path

    from dotdash_manager import state as state_mod
    from dotdash_manager.health import splits
    from dotdash_manager.render import render

    net = loads('''
target = "t"
key = "k"
identity = "i"
authority = "a"
[[server]]
name = "a"
[[canary]]
name = "c1"
watches = "a"
''')
    st = state_mod.load(Path("/nonexistent"), net)
    server = {"domain": "a.example.net", "https_port": 443, "encryption": "E",
              "public_key": state_mod.public_key(st["keys"]["reality_key"])}
    health: dict = {}
    def reading(at, reality, split):
        canary = {"server": "a.example.net", "address": "a.example.net", "checked_at": at,
                  "paths": {"reality": reality, "xhttp": False}, "reality_split": split}
        judge(net, {"a": server, "c1": canary}, health)

    for at in range(1, BURN_AFTER):
        reading(at, False, True)
    assert splits(net, health)[0] == set()  # not yet BURN_AFTER readings
    reading(BURN_AFTER, False, True)
    on, say = splits(net, health)
    assert on == {"a"} and say[0].startswith("split: server a:")
    docs, _ = render(net, st, {"a": server}, split=on)
    assert docs["a"]["parameters"]["hello_split"] == "true"
    st["split"] = sorted(on)

    reading(BURN_AFTER + 1, False, False)  # the split fails too: off
    on, _ = splits(net, health)
    assert on == set()
    docs, _ = render(net, st, {"a": server}, split=on)
    assert docs["a"]["parameters"]["hello_split"] == "false"
    st["split"] = []
    docs, _ = render(net, st, {"a": server}, split=set())
    assert "hello_split" not in docs["a"]["parameters"]  # never said to a server that wasn't split

    reading(BURN_AFTER + 2, True, None)  # REALITY back, a canary from before reality_split
    assert splits(net, health)[0] == set() and "split" not in health["a"]


def test_a_relay_blocked_by_sni_keeps_reality_split_in_devices_configs():
    from pathlib import Path

    from dotdash_manager import state as state_mod
    from dotdash_manager.health import blocked, splits
    from dotdash_manager.render import render

    net = loads('''
target = "t"
key = "k"
identity = "i"
authority = "a"
[[server]]
name = "a"
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
''')
    st = state_mod.load(Path("/nonexistent"), net)
    server = {"domain": "a.example.net", "https_port": 443, "encryption": "E",
              "public_key": state_mod.public_key(st["keys"]["reality_key"])}
    relay = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E"}
    other = {**relay, "entry_host": "203.0.113.6", "site": "www.example.org"}
    health: dict = {}
    for at in range(1, BURN_AFTER + 1):
        c1 = {"server": "www.example.net", "address": "203.0.113.5", "checked_at": at,
              "paths": {"reality": False, "xhttp": True}, "reality_split": True}
        c2 = {"server": "www.example.org", "address": "203.0.113.6", "checked_at": at,
              "paths": {"reality": True, "xhttp": True}, "reality_split": True}
        judge(net, {"a": server, "r1": relay, "r2": other, "c1": c1, "c2": c2}, health)
    off, _ = blocked(net, {"r1": relay, "r2": other}, health, set())
    on, say = splits(net, health)
    assert off == {"r1": {"reality"}} and on == {"r1"} and say[0].startswith("split: relay r1:")
    docs, _ = render(net, st, {"a": server, "r1": relay, "r2": other}, off=off, split=on)
    assert docs["a"]["parameters"]["relays"].splitlines() == [
        "203.0.113.5 www.example.net P S E off=reality split", "203.0.113.6 www.example.org P S E"]
    assert "hello_split" not in docs["a"]["parameters"]
    assert splits(net, health, burnt={"r1"})[0] == set()  # a burnt relay stays out


def test_a_reality_only_relay_through_only_split_is_split_not_burnt():
    from dotdash_manager.health import splits

    net = loads(ROSTER)
    health: dict = {}
    for at in range(1, BURN_AFTER + 2):
        c1 = {"server": R1["site"], "address": R1["entry_host"], "checked_at": at, "internet": True,
              "paths": {"reality": False}, "reality_split": True, "blocked_by": "sni"}
        facts = {"r1": R1, "r2": R2, "c1": c1, "c2": canary(R2, at, True)}
        burnt, say = judge(net, facts, health)
    assert burnt == set() and health["r1"]["fails"] == 0 and not any(line.startswith("burnt:") for line in say)
    off, _ = blocked(net, facts, health, burnt)
    on, _ = splits(net, health, burnt)
    assert off == {"r1": {"reality"}} and on == {"r1"}
    # The split failing too: every path blocked, and it burns.
    for at in range(BURN_AFTER + 2, 2 * BURN_AFTER + 2):
        c1 = {**c1, "checked_at": at, "reality_split": False}
        burnt, _ = judge(net, {**facts, "c1": c1, "c2": canary(R2, at, True)}, health)
    assert burnt == {"r1"} and blocked(net, facts, health, burnt)[0] == {}


def test_a_burnt_verdict_says_what_blocks_it():
    net = loads('''
target = "t"
key = "k"
identity = "i"
authority = "a"
[[server]]
name = "a"
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
''')
    relay = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E"}
    other = {**relay, "entry_host": "203.0.113.6", "site": "www.example.org"}
    health: dict = {}
    for at in range(1, BURN_AFTER + 1):
        c1 = {"server": "www.example.net", "address": "203.0.113.5", "checked_at": at,
              "paths": {"reality": False}, "blocked_by": "ip"}
        c2 = {"server": "www.example.org", "address": "203.0.113.6", "checked_at": at, "paths": {"reality": True}}
        burnt, say = judge(net, {"r1": relay, "r2": other, "c1": c1, "c2": c2}, health)
    assert burnt == {"r1"} and "its address is blocked" in say[0], say
    assert "cause" not in health["r2"]


def test_a_burst_freeze_is_a_cause_and_takes_reality_alone_off():
    net = loads('''
target = "t"
key = "k"
identity = "i"
authority = "a"
[[server]]
name = "a"
[[relay]]
name = "r1"
[[canary]]
name = "c1"
watches = "r1"
''')
    relay = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E"}
    health: dict = {}
    c1 = {"server": "www.example.net", "address": "203.0.113.5", "checked_at": 1,
          "paths": {"reality": False, "xhttp": True}, "burst": True, "blocked_by": "burst"}
    burnt, _ = judge(net, {"r1": relay, "c1": c1}, health)
    assert burnt == set() and health["r1"]["cause"] == "burst" and health["r1"]["paths"] == {"reality": 1, "xhttp": 0}
    assert "page opens several connections" in CAUSES["burst"]


def test_a_certificate_running_out_is_said_and_one_unknown_is_not():
    from dotdash_manager.health import CERT_DAYS, certs

    net = loads(ROSTER)
    server = {"domain": "s.example.net", "https_port": 443, "public_key": "P", "encryption": "E", "cert_days": 3}
    facts = {"s": server, "r1": {**R1, "cert_days": -2}, "r2": {**R2, "cert_days": CERT_DAYS}}
    check = ": renewal is failing, check its ACME (for acme-dns, that it runs and answers)"
    assert certs(net, facts) == [f"certificate: server s: its site's certificate runs out in 3 day(s){check}",
                                 f"certificate: relay r1: its site's certificate ran out 2 day(s) ago{check}"]
    assert certs(net, {"s": {**server, "cert_days": None}, "r1": R1}) == []


def test_report_says_the_certificates_running_out_from_the_kept_facts(tmp_path, monkeypatch):
    from dotdash_manager import cli
    from typer.testing import CliRunner

    (tmp_path / "network.toml").write_text(ROSTER)
    st = state.load(Path("/nonexistent"), loads(ROSTER))
    st["facts"] = {"r1": {"id": "inst_R1", "at": 0, "facts": {**R1, "cert_days": 5}}}
    state.save(tmp_path / "dotdash-state.json", st)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(state, "lock", lambda path: 0)
    r = CliRunner().invoke(cli.app, ["report"])
    assert r.exit_code == 0 and r.output.splitlines()[-1].startswith("certificate: relay r1: its site's certificate runs out in 5")


def sync_with(tmp_path, monkeypatch, roster: str, st: dict, facts: dict):
    """sync in tmp_path against a stand-in morzer: run(code) answers every
    publish with code, and returns sync's exit code, the documents it
    published by name and the state it kept."""
    import json
    import subprocess

    from dotdash_manager import cli
    from typer.testing import CliRunner

    (tmp_path / "network.toml").write_text(roster)
    state.save(tmp_path / "dotdash-state.json", st)
    sent, answer = {}, {"code": 0}

    class Stand:
        def __init__(self, *_):
            pass

        def gather(self, *_):
            return facts

        def rows(self):
            return {}

        def publish(self, m, doc, dry_run):
            sent[m.name] = doc
            return subprocess.CompletedProcess([], answer["code"], "", "target down")

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(state, "lock", lambda path: 0)
    monkeypatch.setattr(cli, "Morzer", Stand)

    def run(code: int = 0):
        answer["code"] = code
        sent.clear()
        r = CliRunner().invoke(cli.app, ["sync"])
        return r.exit_code, dict(sent), json.loads((tmp_path / "dotdash-state.json").read_text())
    return run


def test_a_server_whose_publish_failed_stays_split_for_the_next_sync(tmp_path, monkeypatch):
    roster = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n'
    st = {**state.load(Path("/nonexistent"), loads(roster)), "split": ["a"]}
    run = sync_with(tmp_path, monkeypatch, roster, st, {})
    # No longer split: hello_split off, which a failed publish never delivered.
    code, sent, kept = run(1)
    assert code == 1 and sent["a"]["parameters"]["hello_split"] == "false" and kept["split"] == ["a"]
    assert "inst_A" not in kept["published"]
    code, sent, kept = run(0)
    assert code == 0 and sent["a"]["parameters"]["hello_split"] == "false" and kept["split"] == []
    assert "inst_A" in kept["published"]
    assert "hello_split" not in run(0)[1]["a"]["parameters"]


def test_via_is_unset_only_on_a_relay_a_document_gave_it(tmp_path, monkeypatch):
    roster = ('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n[[server]]\nname = "s"\nid = "inst_S"\nkey = "RWs"\n'
              '[[relay]]\nname = "r1"\nid = "inst_R1"\nkey = "RW1"\n[[relay]]\nname = "r2"\nid = "inst_R2"\nkey = "RW2"\n')
    via = roster + 'via = ["r1"]\n'
    st = state.load(Path("/nonexistent"), loads(roster))
    server = {"domain": "s.example.net", "https_port": 443, "public_key": state.public_key(st["keys"]["reality_key"]),
              "encryption": "E"}
    run = sync_with(tmp_path, monkeypatch, via, st, {"s": server, "r1": {**R1, "via": True}, "r2": {**R2, "via": True}})
    _, sent, kept = run(0)
    assert "via" in sent["r2"]["parameters"] and kept["via"] == ["r2"]
    assert "unset" not in sent["r1"], "r1 never had via: a release that doesn't manage it would refuse the document"
    (tmp_path / "network.toml").write_text(roster)
    _, sent, kept = run(1)
    assert sent["r2"]["unset"] == {"parameters": ["via", "via_link", "via_fingerprint"]} and kept["via"] == ["r2"]
    _, sent, kept = run(0)
    assert "unset" in sent["r2"] and kept["via"] == []
    assert "unset" not in run(0)[1]["r2"]

