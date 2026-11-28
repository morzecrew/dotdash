import base64
import fcntl
import json
import os
import stat
import uuid

import pytest
from dotdash_manager import state
from dotdash_manager.cli import Options
from dotdash_manager.roster import loads


def test_public_key_is_x25519():
    # RFC 7748 §6.1, Alice.
    private = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    public = state.public_key(state.b64url(private))
    assert base64.urlsafe_b64decode(public + "=").hex() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"


def test_load_keeps_what_it_made_and_save_is_private(tmp_path):
    net = loads('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\nsubscription = true\n'
                '[[group]]\nname = "g"\ndevices = ["phone"]\n[[group]]\nname = "h"\n[[client]]\nname = "home"\ndevice = "phone"\n')
    path = tmp_path / "dotdash-state.json"
    first = state.load(path, net)
    assert set(first["keys"]) == {"g", "h"} and set(first["keys"]["g"]) == set(state.SHARED_KEYS)
    assert first["keys"]["g"]["relay_seed"] != first["keys"]["h"]["relay_seed"] and len(first["keys"]["g"]["relay_seed"]) == 64
    assert set(first["ids"]) == {"phone"} and "home" in first["passwords"]
    state.save(path, first)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert state.load(path, net) == json.loads(path.read_text()) == first


def test_one_taken_out_and_added_again_gets_a_new_id_and_password(tmp_path):
    head = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\nsubscription = true\n'
    full = loads(head + '[[group]]\nname = "g"\ndevices = ["phone", "tv"]\n[[relay]]\nname = "r1"\n[[canary]]\nname = "c1"\n'
                 'watches = "r1"\n[[client]]\nname = "home"\ndevice = "phone"\n')
    path = tmp_path / "dotdash-state.json"
    first = state.load(path, full)
    # A relay has no id here: each group's servers derive it.
    assert set(first["ids"]) == {"phone", "tv", "canary-c1"}
    state.save(path, first)
    gone = state.load(path, loads(head + '[[group]]\nname = "g"\ndevices = ["tv"]\n'))
    assert set(gone["ids"]) == {"tv"} and gone["passwords"] == {}
    assert gone["ids"]["tv"] == first["ids"]["tv"] and gone["keys"] == first["keys"]
    state.save(path, gone)
    back = state.load(path, full)
    for name in "phone", "canary-c1":
        assert back["ids"][name] != first["ids"][name]
    assert back["passwords"]["home"] != first["passwords"]["home"]


def test_ids_that_differ_only_in_bytes_6_and_7_are_one_to_xray(monkeypatch):
    from dotdash_manager import Refused
    a = "3f2c1f0e-8a4b-4c1d-9e2f-0a1b2c3d4e5f"
    a67, fresh = a[:14] + "ffff" + a[18:], "6b1d2c3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e"
    for other in a, a67, a67.upper():
        with pytest.raises(Refused, match="phone and tv have ids that differ only in bytes 6 and 7"):
            state.check_ids({"phone": a, "tv": other})
    state.check_ids({"phone": a, "tv": a[:12] + "0" + a[13:], "pc": a[:19] + "0" + a[20:]})
    # A new one is drawn again until Xray tells it from the others.
    made = iter([uuid.UUID(a67), uuid.UUID(fresh)])
    monkeypatch.setattr(state.uuid, "uuid4", lambda: next(made))
    assert state.new_id({"phone": a}) == fresh


def test_a_state_from_before_groups_gives_its_keys_to_the_first_group(tmp_path):
    """Its one set of keys was its servers'; a group renamed later gets new
    ones, and its old ones are kept to name it back."""
    path = tmp_path / "dotdash-state.json"
    old = {k: make() for k, make in state.SHARED_KEYS.items() if k != "relay_seed"}
    path.write_text(json.dumps({"keys": old, "ids": {"phone": str(uuid.uuid4()), "relay-r1": str(uuid.uuid4())},
                                "via": ["r1"], "rotation": {"phase": "swapped", "since": 1, "second": {"reality_key": "o"}}}))
    head = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'
    st = state.load(path, loads(head + '[[group]]\nname = "a"\ndevices = ["phone"]\n[[group]]\nname = "b"\n'))
    assert st["keys"]["a"] == {**old, "relay_seed": st["keys"]["a"]["relay_seed"]} and st["keys"]["b"]["reality_key"] != old["reality_key"]
    assert st["rotation"]["second"] == {"a": {"reality_key": "o"}} and "via" not in st and set(st["ids"]) == {"phone"}
    state.save(path, st)
    renamed = state.load(path, loads(head + '[[group]]\nname = "c"\ndevices = ["phone"]\n'))
    assert renamed["keys"]["a"] == st["keys"]["a"] and renamed["keys"]["c"]["reality_key"] != old["reality_key"]


def test_save_leaves_nothing_beside_the_state(tmp_path):
    path = tmp_path / "dotdash-state.json"
    state.save(path, {"a": 1})
    state.save(path, {"a": 2})
    assert sorted(p.name for p in tmp_path.iterdir()) == ["dotdash-state.json"]
    assert json.loads(path.read_text()) == {"a": 2}


def test_one_run_at_a_time(tmp_path):
    path = tmp_path / "dotdash-state.json"
    held = state.lock(path)
    other = os.open(tmp_path / "dotdash-state.lock", os.O_RDWR)
    with pytest.raises(BlockingIOError):
        fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.close(held)
    fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.close(other)


def test_no_state_beside_a_joined_roster_is_refused_unless_new_state(tmp_path, monkeypatch):
    from dotdash_manager import Refused

    monkeypatch.setattr(state, "lock", lambda path: 0)
    roster = tmp_path / "network.toml"
    roster.write_text('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n[[group]]\nname = "g"\n'
                      '[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n')
    for dry_run in False, True:
        with pytest.raises(Refused, match="names a joined: a new state gives every server new keys"):
            Options(roster, "morzer").open(dry_run)
    assert not (tmp_path / "dotdash-state.json").exists()
    keys = Options(roster, "morzer", new_state=True).open()[1]["keys"]
    assert Options(roster, "morzer").open()[1]["keys"] == keys, "once there, it is the state"


def test_a_dry_run_keeps_no_state(tmp_path):
    roster = tmp_path / "network.toml"
    roster.write_text('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n[[group]]\nname = "g"\ndevices = ["phone"]\n')
    o = Options(roster, "morzer")
    st = o.open(dry_run=True)[1]
    assert "phone" in st["ids"] and not o.state.exists()
    o.open()
    assert json.loads(o.state.read_text())["keys"] == o.open()[1]["keys"]
