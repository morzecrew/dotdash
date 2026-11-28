from dotdash_manager.addresses import DAYS, WINDOW, record, seen
from dotdash_manager.morzer import check

T = 1_699_920_000  # 2023-11-14 00:00 UTC
SAY = "if its link may have leaked, renew a and sync"


def reading(at: int, devices: dict) -> dict:
    return {"addresses": {"at": at, "devices": devices}}


def test_three_addresses_at_once_on_one_relay_name_the_device():
    a: dict = {}
    lines = record(a, {"r1": reading(T, {"a@g": 3, "b@g": 2, "relay-x@g": 5, "canary-c@g": 4})}, T)
    assert lines == [f"a: 3 addresses at once on relay r1 at 2023-11-14 00:00 UTC: {SAY}"], \
        "two is a phone; relays and canaries are left out"
    assert seen(a) == lines


def test_two_relays_at_once_name_the_device():
    a: dict = {}
    lines = record(a, {"r1": reading(T, {"a@g": 1, "b@g": 1}), "r2": reading(T + WINDOW, {"a@g": 1}),
                       "r3": reading(T + 2 * WINDOW, {"b@g": 1}), "s": {"domain": "x"}}, T + 3600)
    assert lines == [f"a: on relays r1, r2 at once at 2023-11-14 00:15 UTC: {SAY}"], \
        "b's two readings are too far apart to be at once"


def test_a_reading_is_judged_once():
    a: dict = {}
    facts = {"r1": reading(T, {"a@g": 4}), "r2": reading(T, {"a@g": 1})}
    assert len(record(a, facts, T)) == 2
    assert record(a, facts, T + 3600) == [], "facts that stood in, or did not refresh, said it already"
    facts["r2"] = reading(T + 3600, {"a@g": 1})
    assert record(a, facts, T + 3600) == [], "r1's old reading is no longer at once with r2's new one"
    assert len(seen(a)) == 2


def test_lines_are_kept_for_days():
    a: dict = {}
    record(a, {"r1": reading(T, {"a@g": 3})}, T)
    record(a, {"r1": reading(T + 3600, {"b@g": 3})}, T + 3600)
    assert [x.split(":")[0] for x in seen(a, since=T + 1)] == ["b"]
    later = T + 3600 + DAYS * 86400
    record(a, {"r1": reading(later, {})}, later)
    assert seen(a) == []


def test_a_fleet_without_readings_keeps_nothing():
    a: dict = {}
    assert record(a, {"s": {"domain": "x"}}, T) == []
    assert a == {}


def test_a_relays_reading_passes_its_facts_check_and_a_bad_one_does_not():
    base = {"entry_host": "1.2.3.4", "site": "x", "public_key": "k", "short_id": "s", "encryption": "none"}
    assert check("relay", {**base, **reading(T, {"a@g": 2})})[0] is not None
    assert check("relay", {**base, **reading(T, {"a@g": -1})})[0] is None
    assert check("relay", {**base, **reading(T, {"a b": 1})})[0] is None
