import base64
import fcntl
import json
import os
import stat

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
                'devices = ["phone"]\n[[client]]\nname = "home"\ndevice = "phone"\n')
    path = tmp_path / "dotdash-state.json"
    first = state.load(path, net)
    assert set(first["keys"]) == set(state.SHARED_KEYS) and set(first["ids"]) == {"phone"} and "home" in first["passwords"]
    state.save(path, first)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert state.load(path, net) == json.loads(path.read_text()) == first


def test_one_taken_out_and_added_again_gets_a_new_id_and_password(tmp_path):
    head = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\nsubscription = true\n'
    full = loads(head + 'devices = ["phone", "tv"]\n[[relay]]\nname = "r1"\n[[canary]]\nname = "c1"\nwatches = "r1"\n'
                 '[[client]]\nname = "home"\ndevice = "phone"\n')
    path = tmp_path / "dotdash-state.json"
    first = state.load(path, full)
    state.save(path, first)
    gone = state.load(path, loads(head + 'devices = ["tv"]\n'))
    assert set(gone["ids"]) == {"tv"} and gone["passwords"] == {}
    assert gone["ids"]["tv"] == first["ids"]["tv"] and gone["keys"] == first["keys"]
    state.save(path, gone)
    back = state.load(path, full)
    for name in "phone", "relay-r1", "canary-c1":
        assert back["ids"][name] != first["ids"][name]
    assert back["passwords"]["home"] != first["passwords"]["home"]


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


def test_a_dry_run_keeps_no_state(tmp_path):
    roster = tmp_path / "network.toml"
    roster.write_text('target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\ndevices = ["phone"]\n')
    o = Options(roster, "morzer")
    st = o.open(dry_run=True)[1]
    assert "phone" in st["ids"] and not o.state.exists()
    o.open()
    assert json.loads(o.state.read_text())["keys"] == o.open()[1]["keys"]
