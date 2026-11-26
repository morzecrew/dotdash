import base64
import json
import subprocess

import pytest
from dotdash_manager import Refused, adopt, state
from dotdash_manager.cli import app
from dotdash_manager.roster import loads
from typer.testing import CliRunner

ROSTER = ('target = "file:///t"\nkey = "k"\nidentity = "i"\nauthority = "a"\nsubscription = true\n'
          'devices = ["phone", "laptop"]\n[[server]]\nname = "a"\n[[relay]]\nname = "r1"\n')
PHONE, OLD, R1 = "6e3c4bd2-5a4f-4b8e-9d1e-0f2a3b4c5d6e", "0f2a3b4c-5d6e-4b8e-9d1e-6e3c4bd25a4f", "1d1e0f2a-3b4c-4d6e-8e3c-4bd25a4f9d1e"


def server_output(clients: str, **override) -> str:
    """What adopt.COMMAND prints on a server holding these."""
    values = {k: make() for k, make in state.SHARED_KEYS.items()} | override | {"vless_clients": clients}
    return "".join(f"{k} {base64.b64encode(v.encode()).decode()}\n" for k, v in values.items())


def test_command_prints_what_parse_reads(tmp_path):
    for k, make in state.SHARED_KEYS.items():
        (tmp_path / k).write_text(make() + "\n")
    (tmp_path / "vless_clients").write_text(f"{PHONE} phone\n")
    out = subprocess.run(["sh", "-c", adopt.COMMAND.replace("/run/dotdash/secrets", str(tmp_path))],
                         capture_output=True, text=True, check=True).stdout
    keys, ids, unnamed, desktops = adopt.parse(out)
    assert set(keys) == set(state.SHARED_KEYS) and ids == {"phone": PHONE} and unnamed == 0 and desktops == set()
    assert keys["xhttp_path"] == (tmp_path / "xhttp_path").read_text().strip()
    (tmp_path / "kcp_seed").unlink()
    r = subprocess.run(["sh", "-c", adopt.COMMAND.replace("/run/dotdash/secrets", str(tmp_path))], capture_output=True)
    assert r.returncode != 0


def test_parse_refuses_what_no_server_printed():
    good = server_output(f"{PHONE} phone\n")
    for text, says in [
        (good + "upstreams eA==\n", "none of its shared keys"),
        (good.replace("kcp_seed", "#kcp"), "none of its shared keys"),
        ("\n".join(line for line in good.splitlines() if not line.startswith("kcp_seed")), "lacks kcp_seed"),
        (server_output("nope phone\n"), "does not start with a UUID"),
        (server_output(f"{PHONE} Phone\n"), "not a name the roster can hold"),
        (server_output(f"{PHONE} phone\n{OLD} phone\n"), "names phone twice"),
        (server_output("x", reality_key="notakey"), "not an X25519 private key"),
        (server_output("x", vless_seed="two words"), "more than one word"),
    ]:
        with pytest.raises(Refused, match=says):
            adopt.parse(text)


def test_take_keeps_the_roster_names_and_says_who_moves():
    net = loads(ROSTER)
    st = {"keys": {k: "made" for k in state.SHARED_KEYS}, "ids": {"phone": "new", "laptop": "new2"}}
    keys, ids, unnamed, _ = adopt.parse(server_output(f"# devices\n{PHONE} phone\n{OLD} tablet\n{R1} relay-r1\n{OLD}\n"))
    said = adopt.take(st, net, keys, ids, unnamed)
    assert st["keys"] == keys and st["ids"]["phone"] == PHONE and st["ids"]["relay-r1"] == R1 and st["ids"]["laptop"] == "new2"
    assert said[0] == "adopted: the server's keys; ids of 2 of the roster's 3 names"
    assert "new to the server, so new links: laptop" in said
    assert "losing access at the next sync unless added: tablet" in said[2]
    assert said[3].startswith("1 line(s)")


def test_cli_adopts_once_and_not_after_a_publish(tmp_path, monkeypatch):
    (tmp_path / "network.toml").write_text(ROSTER)
    monkeypatch.chdir(tmp_path)
    # One process runs every invocation here, and a run's lock lasts as long as it.
    monkeypatch.setattr(state, "lock", lambda path: 0)
    run = CliRunner().invoke
    out = server_output(f"{PHONE} phone\n")
    r = run(app, ["adopt", "a"], input=out)
    assert r.exit_code == 0, r.output
    st = json.loads((tmp_path / "dotdash-state.json").read_text())
    assert st["ids"]["phone"] == PHONE and st["keys"] == adopt.parse(out)[0]
    assert run(app, ["adopt", "r1"], input=out).exit_code != 0
    st["published"] = {"inst_1": {"digest": "d", "at": 1}}
    (tmp_path / "dotdash-state.json").write_text(json.dumps(st))
    r = run(app, ["adopt", "a"], input=server_output(f"{OLD} phone\n"))
    assert r.exit_code != 0 and "already published" in str(r.exception)
    assert run(app, ["adopt", "a", "--force"], input=server_output(f"{OLD} phone\n")).exit_code == 0
    assert json.loads((tmp_path / "dotdash-state.json").read_text())["ids"]["phone"] == OLD


def test_adopt_makes_the_state_of_a_roster_naming_the_server_joined(tmp_path, monkeypatch):
    (tmp_path / "network.toml").write_text(ROSTER.replace('name = "a"\n', 'name = "a"\nid = "inst_A"\nkey = "RWa"\n'))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(state, "lock", lambda path: 0)
    out = server_output(f"{PHONE} phone\n")
    r = CliRunner().invoke(app, ["adopt", "a"], input=out)
    assert r.exit_code == 0, r.output
    assert json.loads((tmp_path / "dotdash-state.json").read_text())["keys"] == adopt.parse(out)[0]


def test_parse_takes_the_first_word_of_a_key_file_and_no_newline():
    keys, _, _, _ = adopt.parse(server_output("", reality_short_id="0123456789abcdef\n"))
    assert keys["reality_short_id"] == "0123456789abcdef"


def test_adopt_names_the_desktops_the_roster_does_not():
    net = loads(ROSTER.replace('devices = ["phone", "laptop"]', 'devices = ["phone", "laptop", "pc"]\ndesktops = ["pc"]'))
    st = {"keys": {}, "ids": {}}
    PC = "2e3c4bd2-5a4f-4b8e-9d1e-0f2a3b4c5d6e"
    keys, ids, unnamed, desktops = adopt.parse(server_output(f"{PHONE} phone mobile\n{OLD} laptop desktop\n{PC} pc desktop\n"))
    assert desktops == {"laptop", "pc"}
    said = adopt.take(st, net, keys, ids, unnamed, desktops)
    assert said[-1] == ("desktops on the server but not in the roster's desktops, getting CDN links at the next sync "
                        "unless added: laptop")
