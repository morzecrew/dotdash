import json
import shutil
import subprocess

import pytest
from dotdash_manager import Refused, join, state
from dotdash_manager.cli import app
from dotdash_manager.roster import loads, with_joined
from typer.testing import CliRunner

ROSTER = ('target = "file:///t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'
          '[[server]]\nname = "a"\n[[relay]]\nname = "r1"\n[[relay]]\nname = "r2"\nid = "inst_2"\nkey = "RW2"\n')
DOC = {"parameters": {"dotdash_servers": "a.example", "ipv6": "allow"},
       "secrets": {"dotdash_id": "6e3c4bd2-5a4f-4b8e-9d1e-0f2a3b4c5d6e", "vless_clients": "id1 phone\nid2 laptop"}}


def make(kind="relay", doc=DOC, **kw):
    net = loads(ROSTER)
    m = net.find({"server": "a", "relay": "r1"}[kind])
    return join.script(m, "s3://b/net", "RWauth", "age1me", kw.pop("recovery", "age1me"), doc, **kw)


def test_a_relay_script_is_sh_and_ends_in_its_id_and_key():
    s = make(site="site.example", entry_host="203.0.113.7", credentials="kind: s3\nsecret: x\n")
    subprocess.run(["sh", "-n"], input=s, text=True, check=True)
    if shutil.which("shellcheck"):
        subprocess.run(["shellcheck", "-s", "sh", "-"], input=s, text=True, check=True)
    assert "--set site=site.example --set entry_host=203.0.113.7" in s
    assert "--set dotdash_servers=a.example" in s and "--recovery-recipient age1me" in s
    assert "morzer secret set vless_clients <<'DOTDASH_END'\nid1 phone\nid2 laptop\nDOTDASH_END" in s
    assert "morzer secret set sync_target <<'DOTDASH_END'\nkind: s3\nsecret: x\nDOTDASH_END" in s
    assert "backup target add s3://b/net --credentials sync_target" in s
    assert "recipients list --json | grep -qF age1me || morzer secret recipients add age1me --kind recovery" in s
    assert "sync.target=s3://b/net sync.authority=RWauth sync.recipient=age1me sync.enabled=true" in s
    assert s.index("sync.enabled=true") < s.index("morzer apply") < s.index("printf 'dotdash-joined")


def test_what_each_kind_needs():
    s = make("server", None, domain="a.example")
    assert "installing it needs join --domain and --upstreams <file>' >&2\nexit 1\nelse" in s and "morzer init" not in s
    s = make("server", None, domain="a.example", upstreams="socks5://u:p@h:1080\n")
    assert "--domain a.example" in s and "morzer secret set upstreams <<'DOTDASH_END'\nsocks5://u:p@h:1080\nDOTDASH_END" in s
    assert "or --site and --entry-host' >&2\nexit 1" in make(site="site.example")
    assert "--domain own.example --profile own-site" in make(domain="own.example")
    with pytest.raises(Refused, match="ends the script"):
        make("server", None, domain="a.example", upstreams="x\nDOTDASH_END\n")
    assert "--set 'note=a b'" in make(doc={"parameters": {"note": "a b"}}, domain="own.example")


def test_an_installed_machine_only_starts_following(tmp_path):
    """The script against a stand-in morzer, on a machine where the relay is
    installed already: no init, no secrets, no apply; sync on, the recovery
    recipient, and its row."""
    log = tmp_path / "calls"
    (tmp_path / "morzer").write_text(f'#!/bin/sh\necho "$*" >>{log}\n[ "$1 $2" != "fleet publish" ] || [ "${{3:-}}" != --dry-run ] || '
                                     'echo \'{"data": {"row": {"installation_id": "inst_7", "signing_key": "RW7="}}}\'\n')
    (tmp_path / "morzer").chmod(0o755)
    s = make(site="site.example", entry_host="203.0.113.7").replace("/etc/dotdash-relay", str(tmp_path))
    out = subprocess.run(["sh"], input=s, capture_output=True, text=True, env={"PATH": f"{tmp_path}:/usr/bin:/bin"}, check=True).stdout
    calls = log.read_text().splitlines()
    assert not any(c.startswith(("init", "secret set", "apply")) for c in calls), calls
    assert "secret recipients add age1me --kind recovery" in calls
    assert calls[0].startswith("config set sync.target=s3://b/net") and calls[-2:] == ["fleet publish", "fleet publish --dry-run --json"]
    assert "installed here already" in out and join.marker(out.splitlines()[-1], "r1") == ("inst_7", "RW7=")


def test_the_script_prints_the_row_it_published(tmp_path):
    """The script's last two lines, against a stand-in morzer."""
    bin_ = tmp_path / "morzer"
    bin_.write_text('#!/bin/sh\nprintf \'{\\n  "data": {"row": {"installation_id": "inst_01ab",\\n "signing_key": "RWQabc+/="}}}\\n\'\n')
    bin_.chmod(0o755)
    tail = "\n".join(make(domain="own.example").splitlines()[-3:])
    out = subprocess.run(["sh", "-c", tail], capture_output=True, text=True, env={"PATH": f"{tmp_path}:/usr/bin:/bin"}, check=True).stdout
    assert join.marker(out, "r1") == ("inst_01ab", "RWQabc+/=")


def test_marker():
    assert join.marker("Applying…\n", "r1") is None
    for line, says in [("dotdash-joined r2 inst_1 RW1", "another machine"), ("dotdash-joined r1 inst_1", "incomplete"),
                       ("dotdash-joined r1  ", "incomplete"), ("dotdash-joined r1 nope RW1", "no installation id")]:
        with pytest.raises(Refused, match=says):
            join.marker(line, "r1")


def test_status_knows_who_joined_from_the_state(tmp_path, monkeypatch):
    bin_ = tmp_path / "morzer"
    bin_.write_text('#!/bin/sh\necho "$*" >>calls\necho \'{"data": {"rows": []}}\'\n')
    bin_.chmod(0o755)
    (tmp_path / "network.toml").write_text(ROSTER)
    (tmp_path / "dotdash-state.json").write_text(json.dumps({"joined": {"r1": {"id": "inst_01ab", "key": "RWQabc="}}}))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(state, "lock", lambda path: 0)
    r = CliRunner().invoke(app, ["--morzer", str(bin_), "status"])
    # r1 joined and has published no row yet.
    assert r.exit_code == 1, r.output
    assert "state ls --target file:///t --expect roster.yaml --json" in (tmp_path / "calls").read_text()
    lines = {line.split()[0]: line for line in r.output.splitlines() if line}
    assert "not joined" not in lines["r1"] and "no verified row" in lines["r1"]
    assert "not joined: run join a" in lines["a"]
    assert "id: inst_01ab" in (tmp_path / "roster.yaml").read_text()
    assert json.loads((tmp_path / "dotdash-state.json").read_text()) == {"joined": {"r1": {"id": "inst_01ab", "key": "RWQabc="}}}


def test_joined_keeps_the_id_and_key_and_the_roster_wins(tmp_path, monkeypatch):
    (tmp_path / "network.toml").write_text(ROSTER)
    monkeypatch.chdir(tmp_path)
    # One process runs every invocation here, and a run's lock lasts as long as it.
    monkeypatch.setattr(state, "lock", lambda path: 0)
    run = CliRunner().invoke
    r = run(app, ["joined", "r1"], input="bootstrap: done\nmorzer: applied\n")
    assert r.exit_code != 0 and "stopped before its last line" in str(r.exception)
    assert "bootstrap: done" in r.output
    # r2 is joined in the roster, the way earlier releases had it: this state is new on purpose.
    r = run(app, ["--new-state", "joined", "r1"], input="applied\ndotdash-joined r1 inst_01ab RWQabc=\n")
    assert r.exit_code == 0, r.output
    assert "applied" in r.output and "dotdash-joined" not in r.output
    st = json.loads((tmp_path / "dotdash-state.json").read_text())
    assert st["joined"]["r1"] == {"id": "inst_01ab", "key": "RWQabc="}
    net = with_joined(loads(ROSTER), st["joined"] | {"r2": {"id": "inst_9", "key": "RW9"}})
    assert (net.find("r1").id, net.find("r1").key) == ("inst_01ab", "RWQabc=") and net.find("r1").joined
    assert net.find("r2").id == "inst_2" and not net.find("a").joined
    assert run(app, ["joined", "nobody"], input="").exit_code != 0
    # The script for r1 run on r2's machine prints r2's installation.
    r = run(app, ["joined", "r1"], input="dotdash-joined r1 inst_2 RW2\n")
    assert r.exit_code != 0 and "ran on r2's installation (inst_2): nothing kept" in str(r.exception)
    assert json.loads((tmp_path / "dotdash-state.json").read_text())["joined"]["r1"]["id"] == "inst_01ab"
