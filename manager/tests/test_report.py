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
    assert next(line for line in lines if "spares waiting" in line).endswith("spares waiting: none")


def test_latency_against_the_canaries_network_and_the_servers():
    from dotdash_manager.health import LATENCIES, record

    h: dict = {}
    for ms in (300, 200, 210, 220):
        record(h, [{"latency_ms": {"reality": ms, "mkcp": ms + 50}, "direct_ms": 100},
                   {"latency_ms": {"reality": ms + 4}, "direct_ms": "slow"}])
    assert h["latency"]["reality"] == [300, 200, 210, 220] and h["latency"]["direct"] == [100] * 4
    record(h, [{"paths": {"reality": True}}])  # a canary from before latencies: nothing
    assert len(h["latency"]["reality"]) == 4
    for _ in range(LATENCIES + 5):
        record(h, [{"latency_ms": {"reality": 1}}])
    assert len(h["latency"]["reality"]) == LATENCIES

    health = {"s": {"latency": {"reality": [200, 210, 220], "direct": [100]}},
              "r1": {"latency": {"reality": [290, 300], "xhttp": [400]}}}
    lines = report(loads(ROSTER), [], DAY, {}, health)
    assert lines[-3].startswith("latency, ms")
    assert lines[-2].split() == ["s", "network", "100", "reality", "210"]
    assert lines[-1] == "r1           network     -   reality 290 (+80 over the servers), xhttp 400"
    assert not any(line.startswith("r2 ") for line in lines[-3:])


def test_each_paths_life_and_the_lifetimes_per_provider():
    now = 40 * DAY
    log = [[0, "r1", "watched"], [10 * DAY, "r1", "off:xhttp"], [20 * DAY, "r1", "burnt"],
           [20 * DAY, "r1", "off:reality"], [20 * DAY, "r1", "off:xhttp"],
           [0, "r2", "watched"], [6 * DAY, "r2", "off:reality"],
           [0, "old", "watched"], [4 * DAY, "old", "burnt"], [4 * DAY, "old", "off:reality"], [5 * DAY, "old", "gone"]]
    health = {"r1": {"paths": {"reality": 3, "xhttp": 3}}, "r2": {"paths": {"reality": 3, "xhttp": 0, "hysteria2": 0}}}
    labels = {"r1": {"provider": "hoster-a", "address_since": "1969-12-22"}, "old": {"provider": "hoster-a"},
              "r2": {"provider": "hoster-b", "address_since": None}}
    lines = report(loads(ROSTER), log, now, {}, health, labels)
    at = lines.index("paths: how long each lasted before it was first blocked (+: never yet)")
    table = {line.split()[0]: line.split()[1:] for line in lines[at + 2:at + 5]}
    # reality, xhttp, xhttp-reality, mkcp, hysteria2: r1's xhttp first went off on day 10, not at its burn.
    assert table["r1"] == ["20d", "0h", "10d", "0h", "-", "-", "-"]
    assert table["r2"] == ["6d", "0h", "40d", "0h+", "-", "-", "40d", "0h+"]
    assert table["old"] == ["4d", "0h", "-", "-", "-", "-"]
    assert lines[at + 5] == ("median to first block: reality 6d 0h (3 blocked); xhttp 10d 0h (1 blocked, 1 never); "
                             "hysteria2 never blocked (1, 40d 0h longest)")
    a = next(line for line in lines if line.startswith("hoster-a "))
    assert "2 burnt, 12d 0h at the median" in a and "addresses 10d 0h old when first watched" in a  # r1 20d, old 4d
    assert next(line for line in lines if line.startswith("hoster-b ")).endswith("0 burnt; 1 never burnt (40d 0h so far)")


def test_the_roster_labels_servers_and_relays_alone():
    import pytest
    from dotdash_manager import Refused

    net = loads(ROSTER.replace('name = "r1"', 'name = "r1"\nprovider = "hoster-a"\naddress_since = 2026-10-01'))
    assert net.relay[0].provider == "hoster-a" and net.relay[0].address_since.isoformat() == "2026-10-01"
    with pytest.raises(Refused, match="provider"):
        loads(ROSTER + '[[canary]]\nname = "c"\nwatches = "s"\nprovider = "x"\n')

