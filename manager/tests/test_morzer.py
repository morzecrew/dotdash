import json
import subprocess
import time

import pytest
from dotdash_manager.morzer import Morzer, check, to_yaml, write_roster
from dotdash_manager.roster import loads

HEAD = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'
RELAY = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "kcp": {"port": 8447, "header": "dtls", "open": "none", "seed": "K"}, "cdn_hosts": ["c.example.net"],
         "traffic": {"started": 1, "devices": {"phone": 10}}, "via": True}
SERVER = {"domain": "a.example.net", "https_port": 443, "public_key": "P", "encryption": "mlkem768x25519plus.native.0rtt.x"}
CANARY = {"server": "www.example.net", "address": "203.0.113.5", "public_key": "", "checked_at": 1, "internet": None,
          "paths": {"reality": True, "xhttp-reality": False}, "reality_split": None, "blocked_by": None,
          "latency_ms": {"reality": 120}, "direct_ms": None}


def test_facts_as_the_bundles_print_them_pass_their_nulls_left_out():
    assert check("relay", RELAY) == (RELAY, "")
    assert check("server", SERVER) == (SERVER, "")
    f, why = check("canary", CANARY)
    assert why == "" and f == {k: v for k, v in CANARY.items() if v is not None}
    assert check("relay", {**RELAY, "kcp": None, "later": [1, {"x": True}]})[0] == {
        **{k: v for k, v in RELAY.items() if k != "kcp"}, "later": [1, {"x": True}]}


@pytest.mark.parametrize(("kind", "doc", "says"), [
    ("relay", [], "not a JSON object"),
    ("relay", {}, "entry_host: Field required"),
    ("relay", {**RELAY, "kcp": {"header": "dtls", "seed": "K"}}, "kcp.port: Field required"),
    ("relay", {**RELAY, "name": "x\n203.0.113.9 evil.example P S E"}, "facts.name holds whitespace"),
    ("relay", {**RELAY, "entry_host": "203.0.113.5 cdn-only"}, "facts.entry_host holds whitespace"),
    ("relay", {**RELAY, "encryption": 'none","address":"evil.example'}, "facts.encryption holds"),
    ("relay", {**RELAY, "site": ""}, "site: String should have at least 1 character"),
    ("relay", {**RELAY, "cdn_hosts": "c.example.net"}, "cdn_hosts: Input should be a valid list"),
    ("relay", {**RELAY, "cdn_only": "false"}, "cdn_only: Input should be a valid boolean"),
    ("relay", {**RELAY, "traffic": {"started": 1, "devices": {"phone": "10"}}}, "traffic.devices.phone"),
    ("server", {**SERVER, "https_port": "443"}, "https_port: Input should be a valid integer"),
    ("server", {**SERVER, "https_port": True}, "https_port: Input should be a valid integer"),
    ("server", {**SERVER, "hysteria2_port": 70000}, "hysteria2_port"),
    ("canary", {**CANARY, "paths": {"reality\x1b[2J": False}}, "facts.paths holds"),
    ("canary", {**CANARY, "paths": {"Reality,xhttp": False}}, "paths.Reality,xhttp.[key]"),
    ("canary", {**CANARY, "paths": {"reality": "true"}}, "paths.reality: Input should be a valid boolean"),
    ("canary", {**CANARY, "internet": "false"}, "internet: Input should be a valid boolean"),
])
def test_facts_that_would_crash_a_sync_or_reach_devices_are_refused(kind, doc, says):
    f, why = check(kind, doc)
    assert f is None and says in why, why
    assert "\x1b" not in why and "evil" not in why, "the reason names keys, never a value"


def test_a_failed_read_takes_the_last_good_facts_for_a_day(tmp_path, capsys):
    net = loads(HEAD + '[[relay]]\nname = "r1"\nid = "inst_R1"\nkey = "RWr"\n')
    mz = Morzer(net, tmp_path / "roster.yaml", "morzer")
    ok = lambda *args, stdin=None: subprocess.CompletedProcess(args, 0, json.dumps({"data": {"facts": json.dumps(RELAY)}}), "")
    fail = lambda *args, stdin=None: subprocess.CompletedProcess(args, 1, "", "age: no identity matched\n")
    kept = {"gone": {"id": "inst_G", "at": 0, "facts": RELAY}}
    mz.run = ok
    assert mz.gather(kept, 1000) == {"r1": RELAY}
    assert kept == {"r1": {"id": "inst_R1", "at": 1000, "facts": RELAY}}, "a machine left the roster: its facts go"
    mz.run = fail
    assert mz.gather(kept, 1000 + 5 * 3600) == {"r1": RELAY}
    err = capsys.readouterr().err
    assert "r1: no facts read: age: no identity matched; its facts of 5 h ago stand in, for 24 h at most" in err
    assert kept["r1"]["at"] == 1000, "a stand-in is no new reading"
    assert mz.gather(kept, 1000 + 25 * 3600) == {}
    assert "its last facts are 25 h old, past 24 h: LEFT OUT of every document" in capsys.readouterr().err
    # Another installation under the name: the old one's facts aren't its.
    other = loads(HEAD + '[[relay]]\nname = "r1"\nid = "inst_NEW"\nkey = "RWr"\n')
    mz = Morzer(other, tmp_path / "roster.yaml", "morzer")
    mz.run = fail
    assert mz.gather(kept, 1001) == {}


def test_a_morzer_call_that_hangs_fails_in_time(tmp_path, monkeypatch):
    from dotdash_manager import morzer

    monkeypatch.setattr(morzer, "TIMEOUT", 0.2)
    bin_ = tmp_path / "morzer"
    bin_.write_text("#!/bin/sh\nexec sleep 30\n")
    bin_.chmod(0o755)
    mz = Morzer(loads(HEAD), tmp_path / "roster.yaml", str(bin_))
    began = time.monotonic()
    r = mz.run("state", "facts", "--json")
    assert time.monotonic() - began < 5
    assert r.returncode == 124 and r.stderr == "morzer state facts gave no answer in 0.2 s: is the target reachable?"


def test_gather_leaves_refused_facts_out_and_says_why(tmp_path, capsys):
    net = loads(HEAD + '[[relay]]\nname = "r1"\nid = "inst_R1"\nkey = "RWr"\n')
    mz = Morzer(net, tmp_path / "roster.yaml", "morzer")
    bad = {**RELAY, "kcp": {"header": "dtls", "seed": "K"}}
    mz.run = lambda *args, stdin=None: subprocess.CompletedProcess(args, 0, json.dumps({"data": {"facts": json.dumps(bad)}}), "")
    assert mz.gather() == {}
    assert "r1: its facts are refused: kcp.port: Field required; left out" in capsys.readouterr().err


def test_to_yaml():
    assert to_yaml({"secrets": {"a": "x\ny"}, "unset": {"parameters": ["relays"]}}) == \
        'secrets:\n  a: "x\\ny"\nunset:\n  parameters: ["relays"]\n'


def test_morzer_roster_lists_who_joined(tmp_path):
    path = tmp_path / "roster.yaml"
    write_roster(path, loads(HEAD))
    assert path.read_text().endswith("installations: []\n")
    write_roster(path, loads(HEAD + '[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n[[relay]]\nname = "r1"\n'))
    assert path.read_text().splitlines()[3:] == ["  - product: dotdash", "    id: inst_A", "    key: RWa"]


def test_rows_keeps_verified_rows_of_joined_machines(tmp_path):
    net = loads(HEAD + '[[relay]]\nname = "r1"\nid = "inst_R1"\nkey = "RWr"\n'
                       '[[relay]]\nname = "r2"\nid = "inst_R2"\nkey = "RWs"\n')
    mz = Morzer(net, tmp_path / "roster.yaml", "morzer")
    out = {"data": {"rows": [
        {"installation_id": "inst_R1", "signature": "verified", "age": "40m", "stale": False,
         "row": {"health": {"services": 5, "running": 4}}},
        {"installation_id": "inst_R2", "signature": "signed-by-another-key", "age": "1m", "row": {"health": {}}},
        {"installation_id": "inst_X", "signature": "verified", "row": {"health": {}}}]}}
    seen = []
    mz.run = lambda *args, stdin=None: seen.append(args) or subprocess.CompletedProcess(args, 0, json.dumps(out), "")
    assert mz.rows() == {"r1": {"age": "40m", "stale": False, "services": 5, "running": 4, "problem": ""}}
    # A machine writes its own row: what is not a count says nothing.
    out["data"]["rows"][0]["row"]["health"] = {"services": "\x1b[2J5", "running": 4}
    assert mz.rows()["r1"]["services"] is None
    out["data"]["rows"][0]["row"]["health"] = ["not", "an", "object"]
    assert mz.rows()["r1"]["running"] is None
    assert seen[0][:3] == ("fleet", "ls", "t") and "--stale-after" in seen[0]
    mz.run = lambda *args, stdin=None: subprocess.CompletedProcess(args, 1, "", "no target")
    assert mz.rows() == {}


def test_gather_reads_facts_side_by_side_and_keeps_who_answered(tmp_path):
    machines = "".join(f'[[relay]]\nname = "r{i}"\nid = "inst_{i}"\nkey = "RW{i}"\n' for i in range(6))
    mz = Morzer(loads(HEAD + machines + '[[relay]]\nname = "new"\n'), tmp_path / "roster.yaml", "morzer")

    def run(*args, stdin=None):
        time.sleep(0.5)
        inst = args[args.index("--installation") + 1]
        if inst == "inst_3":
            return subprocess.CompletedProcess(args, 1, "", "no facts yet")
        return subprocess.CompletedProcess(args, 0, json.dumps({"data": {"facts": json.dumps({**RELAY, "site": inst})}}), "")
    mz.run = run
    began = time.monotonic()
    facts = mz.gather()
    assert time.monotonic() - began < 2
    assert facts == {f"r{i}": {**RELAY, "site": f"inst_{i}"} for i in (0, 1, 2, 4, 5)}
