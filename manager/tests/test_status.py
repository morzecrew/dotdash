"""status from fleet rows and state ls as morzer 0.19 prints them with
--json (tests/fixtures, shaped by its FleetRowStatus, FleetRow, FleetSync and
StateRow), and from what the last sync kept."""

import fcntl
import json
import os
import subprocess
from pathlib import Path

from dotdash_manager import cli, state
from dotdash_manager import status as overview
from dotdash_manager.morzer import Morzer
from dotdash_manager.roster import loads
from typer.testing import CliRunner

FIXTURES = Path(__file__).parent / "fixtures"
NOW = 1_800_000_000
ROSTER = """
target = "file:///t"
key = "k"
identity = "i"
authority = "a"
subscription = true
devices = ["phone", "laptop"]
desktops = ["laptop"]
pools = { p = ["phone", "203.0.113.5"] }
[[server]]
name = "a"
id = "inst_A"
key = "RWa"
cdn_hosts = ["cdn.example.net"]
[[relay]]
name = "r1"
id = "inst_R1"
key = "RWr"
[[relay]]
name = "r2"
id = "inst_R2"
key = "RWs"
via = ["r1"]
spare = true
[[relay]]
name = "r3"
[[canary]]
name = "c1"
id = "inst_C1"
key = "RWc"
watches = "r1"
[[client]]
name = "home"
id = "inst_H"
key = "RWh"
device = "phone"
"""
R1 = {"entry_host": "203.0.113.5", "site": "r1.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
      "own_site": {"xhttp_path": "secretpath"}, "kcp": {"port": 8447, "header": "dtls", "seed": "K"},
      "hysteria2": {"port": 443}, "cdn_hosts": ["c.example.net"], "origin_host": "o.example.net/e/tok/s/", "name": "edge-1"}
STATE = {
    "facts": {"a": {"id": "inst_A", "at": NOW - 600, "facts": {"domain": "a.example.net", "https_port": 443}},
              "r1": {"id": "inst_R1", "at": NOW - 1200, "facts": R1},
              "c1": {"id": "inst_C1", "at": NOW - 1200, "facts": {"checked_at": NOW - 1800, "paths": {"reality": True}}}},
    "health": {"r1": {"fails": 0, "at": NOW - 1800, "paths": {"reality": 3, "xhttp": 0}}},
}


def morzer(net, tmp_path) -> Morzer:
    mz = Morzer(net, tmp_path / "roster.yaml", "morzer")
    out = {"fleet": (FIXTURES / "fleet-ls.json").read_text(), "state": (FIXTURES / "state-ls.json").read_text()}
    mz.run = lambda *args, stdin=None: subprocess.CompletedProcess(args, 0, out[args[0]], "")
    return mz


def test_one_line_per_machine_from_its_row_and_its_newest_document(tmp_path):
    net = loads(ROSTER)
    mz = morzer(net, tmp_path)
    lines, pending, bad = overview.machines(net, STATE, mz.rows(), mz.published(), NOW)
    row = {line.split()[0]: " ".join(line.split()[1:]) for line in lines[1:] if line and not line.endswith("exit-status")}
    assert lines[0].split() == ["machine", "kind", "release", "document", "health", "facts", "canaries"]
    assert row["a"] == "server 0.17.0 applied 7 5/5 up, row 12m ago 10m unwatched"
    # The refused name that would reach the terminal is dropped.
    assert row["r1"] == ("relay 0.17.0 (staged 0.18.0) REFUSED 4 unmanageable: via_link 4/4 up, row 40m ago 20m "
                         "reality off, xhttp ok")
    assert row["r2"] == "relay 0.16.1 applied 1 STALE, row 4h10m ago none unwatched"
    assert row["r3"] == "relay - not joined: run join r3 - - -"
    assert row["c1"] == "canary 0.17.0 sync off not checked, row 20m ago 20m read 30m ago"
    assert row["home"] == "client 0.17.0 pending 2, last fetch unreachable 2/2 up, row 10m ago - -"
    assert "r1: its last facts run didn't replace them: exit-status" in lines
    assert pending and bad
    assert not any("9.9.9" in line for line in lines), "a row that doesn't verify says nothing"


def test_a_document_applied_refused_or_waited_for():
    sync = lambda **kw: {"enabled": True, "applied": None, "refused": None, "fetch": "ok", "pending": [], **kw}
    doc = lambda serial: {"serial": serial, "at": None, "step": "check", "class": None, "names": []}
    assert overview.document(0, None) == ("none published", "ok")
    assert overview.document(3, None) == ("not following the manager", "bad")
    # A refusal older than an apply is past.
    assert overview.document(5, sync(applied=doc(5), refused=doc(4))) == ("applied 5", "ok")
    assert overview.document(5, sync(applied=doc(4), refused=doc(5))) == ("REFUSED 5 check", "bad")
    assert overview.document(5, sync(applied=doc(4), pending=["x"])) == ("pending 5", "pending")
    assert overview.document(5, sync(applied=doc(5), pending=["x"])) == ("applied 5; for the update: x", "ok")


def test_the_topology_names_entries_never_a_key_or_a_path():
    out = "\n".join(overview.topology(loads(ROSTER), STATE))
    assert "  server a: a.example.net:443: reality, xhttp, cdn cdn.example.net" in out
    assert ("  relay r1: 203.0.113.5, site r1.example.net: reality, xhttp, mkcp 8447, hy2 443, cdn c.example.net, "
            "origin o.example.net; name edge-1; off=reality") in out
    assert "  relay r2: no facts yet; via r1 (reality); spare" in out
    assert "  pool p: phone, 203.0.113.5\n  desktops: laptop\n  canary c1 watches r1\n  client home follows phone" in out
    assert not any(s in out for s in ("secretpath", "tok", "K", " P ", " S "))


def test_wait_asks_again_until_every_document_is_applied_or_refused(tmp_path, monkeypatch):
    (tmp_path / "network.toml").write_text('target = "file:///t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'
                                           '[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n')
    (tmp_path / "dotdash-state.json").write_text(json.dumps({}))
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(cli, "POLL", 0)
    row = lambda serial: {"a": {"age": "1m0s ago", "stale": False, "services": 5, "running": 5, "problem": "",
                                "version": "0.17.0", "staged": None, "facts_problem": None,
                                "sync": {"enabled": True, "applied": {"serial": serial, "at": None}, "refused": None,
                                         "fetch": "ok", "pending": []}}}
    seen = iter([row(1), row(1), row(2)])

    def rows(self):
        # While it waits a sync can run: the lock is free, and the state that
        # sync leaves is what the next look reads.
        other = os.open(tmp_path / "dotdash-state.lock", os.O_RDWR)
        fcntl.flock(other, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state.save(tmp_path / "dotdash-state.json",
                   {"facts": {"a": {"id": "inst_A", "at": 0, "facts": {"domain": "a.example.net", "https_port": 443}}}})
        os.close(other)
        return next(seen)

    monkeypatch.setattr(Morzer, "rows", rows)
    monkeypatch.setattr(Morzer, "published", lambda self: {"a": 2})
    r = CliRunner().invoke(cli.app, ["status", "--wait"])
    assert r.exit_code == 0, r.output
    assert "applied 2" in r.output
    assert "server a: a.example.net:443" in r.output, "the state a sync left while it waited is not read"
    monkeypatch.setattr(Morzer, "rows", lambda self: row(1))
    r = CliRunner().invoke(cli.app, ["status", "--wait", "--timeout", "0"])
    assert r.exit_code == 1 and "pending 2" in r.output


def test_a_relay_whose_device_list_is_not_the_one_sent_is_said():
    r2 = loads(ROSTER).find("r2")
    row = {"sync": {"applied": {"serial": 1, "at": "2027-01-15T08:00:00Z"}}}
    applied = 1_800_000_000 - 1_800_000_000 % 86400 + 8 * 3600
    st = lambda at, digest: {"facts": {"r2": {"id": "inst_R2", "at": at, "facts": {"clients": {"count": 2, "digest": digest}}}},
                             "published": {"inst_R2": {"digest": "x", "at": 0, "clients": "0123abcd"}}}
    assert overview.devices(r2, st(applied + 60, "deadbeef"), row) == (
        "r2: its device list (2, digest deadbeef) is not the one the manager sent (digest 0123abcd): "
        "changed on the relay by hand? The manager's next document for it puts it back")
    assert overview.devices(r2, st(applied + 60, "0123abcd"), row) is None
    # Facts read before its last apply carry the list from before it.
    assert overview.devices(r2, st(applied - 60, "deadbeef"), row) is None
