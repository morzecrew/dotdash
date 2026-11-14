import base64
import json
import stat

from dotdash_manager import state
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
