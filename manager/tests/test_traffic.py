from dotdash_manager.traffic import FLOOR, MIN_DAYS, day, record, unusual

MIDNIGHT = 1_699_920_000  # 2023-11-14 00:00 UTC


def counts(started: int, a: int, relay: int = 0) -> dict:
    return {"s": {"traffic": {"started": started, "devices": {"a": a, "relay-r": relay, "canary-c": relay}}}}


def test_a_day_gets_what_the_counters_moved_since_the_last_read():
    t: dict = {}
    record(t, counts(MIDNIGHT, 100), MIDNIGHT)
    assert t["days"][day(MIDNIGHT)] == {}, "the first counts only set where they start"
    record(t, counts(MIDNIGHT, 350, 10**9), MIDNIGHT + 3600)
    assert t["days"][day(MIDNIGHT)] == {"a": 250}, "relays' and canaries' own ids are left out"
    record(t, counts(MIDNIGHT, 350), MIDNIGHT + 7200)
    assert t["days"][day(MIDNIGHT)] == {"a": 250}, "the same facts read again add nothing"


def test_a_restarted_xray_counts_from_zero():
    t: dict = {}
    record(t, counts(MIDNIGHT, 5000), MIDNIGHT)
    record(t, counts(MIDNIGHT + 7000, 40), MIDNIGHT + 7200)
    assert t["days"][day(MIDNIGHT)] == {"a": 40}


def test_facts_without_counts_keep_the_last_ones():
    t: dict = {}
    record(t, counts(MIDNIGHT, 100), MIDNIGHT)
    record(t, {"s": {"domain": "x"}}, MIDNIGHT + 3600)
    record(t, counts(MIDNIGHT, 300), MIDNIGHT + 7200)
    assert t["days"][day(MIDNIGHT)] == {"a": 200}


def test_only_a_day_far_above_the_devices_median_is_unusual():
    t = {"days": {f"2026-01-{i:02}": {"a": 10**8, "b": 10**8} for i in range(1, MIN_DAYS + 1)}}
    assert unusual(t) == []
    t["days"]["2026-01-20"] = {"a": FLOOR + 1, "b": FLOOR - 1}
    lines = unusual(t)
    assert len(lines) == 1 and lines[0].startswith("a: 2.0 GB on 2026-01-20"), "b is under the floor"
    assert unusual(t, since="2026-01-21") == []


def test_a_heavy_device_is_judged_by_its_own_usual_day():
    t = {"days": {f"2026-01-{i:02}": {"a": 10 * FLOOR} for i in range(1, MIN_DAYS + 2)}}
    assert unusual(t) == [], "ten times the floor every day is that device's usual"


def test_no_verdict_before_enough_days():
    t = {"days": {"2026-01-01": {}, "2026-01-02": {"a": 10 * FLOOR}}}
    assert unusual(t) == []


def test_a_fleet_without_counts_keeps_nothing():
    t: dict = {}
    record(t, {"s": {"domain": "x"}}, MIDNIGHT)
    assert t == {}
