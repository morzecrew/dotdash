import hashlib
import json

import pytest
from dotdash_manager import cli, state
from dotdash_manager.roster import loads
from typer.testing import CliRunner

ROSTER = """
target = "file:///t"
key = "k"
identity = "i"
authority = "a"
subscription = true
devices = ["phone", "laptop"]
pools = { p = ["laptop", "198.51.100.9"] }
[[server]]
name = "a"
id = "inst_A"
key = "RWa"
[[relay]]
name = "r1"
id = "inst_R1"
key = "RWr"
[[relay]]
name = "r2"
id = "inst_R2"
key = "RWs"
[[relay]]
name = "r3"
id = "inst_R3"
key = "RWt"
"""
RELAY = {"entry_host": "203.0.113.5", "site": "r1.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}}


@pytest.fixture
def rig(tmp_path, monkeypatch):
    """A roster and the state a sync left: r2 in pool p alone, r3 burnt."""
    (tmp_path / "network.toml").write_text(ROSTER)
    st = state.load(tmp_path / "none", loads(ROSTER))
    a = {"domain": "a.example.net", "https_port": 8443, "public_key": state.public_key(st["keys"]["reality_key"])}
    st["facts"] = {n: {"id": i, "at": 0, "facts": f} for n, i, f in [
        ("a", "inst_A", a), ("r1", "inst_R1", RELAY),
        ("r2", "inst_R2", {**RELAY, "entry_host": "198.51.100.9", "site": "r2.example.net"}),
        ("r3", "inst_R3", {**RELAY, "entry_host": "192.0.2.7", "site": "r3.example.net"})]}
    st["out"] = ["r3"]
    state.save(tmp_path / "dotdash-state.json", st)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(state, "lock", lambda path: 0)
    return tmp_path


def token(rig, device):
    st = json.loads((rig / "dotdash-state.json").read_text())
    return hashlib.sha256(f"{st['keys']['subscription_key']}:{st['ids'][device]}".encode()).hexdigest()[:32]


def test_link_gives_a_device_the_urls_the_servers_serve_it(rig):
    run = CliRunner().invoke
    r = run(cli.app, ["link", "phone"])
    assert r.exit_code == 0, r.output
    t = token(rig, "phone")
    # phone is in no pool: every own-site relay but the burnt one, in roster order.
    assert r.output.splitlines() == [f"https://a.example.net:8443/{t}", f"through the relay r1.example.net: https://r1.example.net/{t}",
                                     f"through the relay r2.example.net: https://r2.example.net/{t}"]
    # laptop's pool holds r2; r1 is in no pool, so every device sees it.
    r = run(cli.app, ["link", "laptop"])
    assert [line.split()[-1] for line in r.output.splitlines()][1:] == [
        f"https://r1.example.net/{token(rig, 'laptop')}", f"https://r2.example.net/{token(rig, 'laptop')}"]
    (rig / "network.toml").write_text(ROSTER.replace("subscription = true", "subscription = true\ndirect = false"))
    r = run(cli.app, ["link", "phone"])
    assert r.output.splitlines()[0] == f"through the relay r1.example.net: https://r1.example.net/{t}"
    assert "a.example.net" not in r.output


def test_link_refuses_what_no_server_serves(rig):
    run = CliRunner().invoke
    assert "is not in" in str(run(cli.app, ["link", "tv"]).exception)
    (rig / "network.toml").write_text(ROSTER.replace('"laptop"]', '"laptop", "tv"]', 1))
    assert "tv has no id yet: run sync" in str(run(cli.app, ["link", "tv"]).exception)
    (rig / "network.toml").write_text(ROSTER.replace("subscription = true", "subscription = false"))
    assert "client-config --output -- phone" in str(run(cli.app, ["link", "phone"]).exception)


def test_link_qr_by_qrencode_with_the_url_on_its_stdin(rig, monkeypatch, capfd):
    bin_ = rig / "bin"
    bin_.mkdir()
    (bin_ / "qrencode").write_text('#!/bin/sh\necho "QR $* $(cat)"\n')
    (bin_ / "qrencode").chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_}:/usr/bin:/bin")
    r = CliRunner().invoke(cli.app, ["link", "phone", "--qr"])
    assert r.exit_code == 0, r.output
    # qrencode writes to the terminal itself, past the runner's capture.
    assert f"QR -t ANSIUTF8 https://a.example.net:8443/{token(rig, 'phone')}" in capfd.readouterr().out.splitlines()


def test_renew_gives_a_device_a_new_id_and_prints_its_new_urls(rig):
    old, laptop = token(rig, "phone"), token(rig, "laptop")
    r = CliRunner().invoke(cli.app, ["renew", "phone"])
    assert r.exit_code == 0, r.output
    new = token(rig, "phone")
    assert new != old and f"https://a.example.net:8443/{new}" in r.output.splitlines()
    assert token(rig, "laptop") == laptop and "Run sync" in r.output
