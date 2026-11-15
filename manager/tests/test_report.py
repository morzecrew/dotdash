from dotdash_manager.health import BURN_AFTER, events
from dotdash_manager.report import history, report
from dotdash_manager.roster import loads

ROSTER = """
target = "t"
key = "k"
identity = "i"
authority = "a"
[[server]]
name = "s"
[[relay]]
name = "r1"
[[relay]]
name = "r2"
[[relay]]
name = "r3"
spare = true
"""
DAY = 86400


def test_events_say_what_changed_between_two_readings():
    up = {"fails": 0, "at": 10, "paths": {"reality": 0, "xhttp": 0}}
    burnt = {"fails": BURN_AFTER, "at": 20, "since": 10, "paths": {"reality": BURN_AFTER, "xhttp": BURN_AFTER - 1}}
    assert events({}, {"r1": up}, {}, {}, 99) == [[10, "r1", "watched"]]
    assert events({"r1": up}, {"r1": burnt}, {}, {"r3": "r1"}, 99) == \
        [[20, "r1", "burnt"], [20, "r1", "off:reality"], [99, "r3", "stands-in:r1"]]
    back = {**up, "at": 30}
    assert events({"r1": burnt}, {"r1": back}, {"r3": "r1"}, {}, 99) == \
        [[30, "r1", "back"], [30, "r1", "on:reality"], [99, "r3", "waits"]]
    assert events({"r1": burnt}, {}, {}, {}, 99) == [[99, "r1", "gone"]]
    # Still burnt, still standing: nothing new.
    assert events({"r1": burnt}, {"r1": {**burnt, "fails": BURN_AFTER + 1}}, {"r3": "r1"}, {"r3": "r1"}, 99) == []


def test_a_relays_history_and_the_fleets_median():
    now = 40 * DAY
    log = [[0, "r1", "watched"], [10 * DAY, "r1", "burnt"], [10 * DAY, "r1", "off:reality"],
           [10 * DAY, "r3", "stands-in:r1"], [12 * DAY, "r1", "back"], [20 * DAY, "r1", "burnt"],
           [0, "r2", "watched"], [0, "old", "watched"], [4 * DAY, "old", "burnt"], [5 * DAY, "old", "gone"]]
    h = history(log, "r1", now)
    assert h["lasted"] == 10 * DAY and not h["lasting"] and h["burnt_now"]
    assert h["down"] == 2 * DAY + 20 * DAY and h["off"]["reality"] == 1
    assert history(log, "old", now)["down"] == DAY and history(log, "r3", now)["stood"] == 1
    lines = report(loads(ROSTER), log, now, {"r3": "r1"})
    r1 = next(line for line in lines if line.startswith("r1 "))
    assert "burnt" in r1 and "10d 0h" in r1 and "reality×1" in r1
    assert next(line for line in lines if line.startswith("old ")).split()[1:3] == ["gone", "gone"]
    assert next(line for line in lines if line.startswith("r3 ")).split()[1:3] == ["spare", "standing"]
    assert lines[1].startswith("s ") and "1970-01-01" in r1
    assert "2 burnt, lasting 7d 0h at the median" in "\n".join(lines)  # r1 10d, old 4d
    assert "1 never burnt, watched 40d 0h so far" in "\n".join(lines)
    assert lines[-1].endswith("spares waiting: none")
