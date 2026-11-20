import json
import subprocess
import time

from dotdash_manager.morzer import Morzer, to_yaml, write_roster
from dotdash_manager.roster import loads

HEAD = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'


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
        return subprocess.CompletedProcess(args, 0, json.dumps({"data": {"facts": json.dumps({"id": inst})}}), "")
    mz.run = run
    began = time.monotonic()
    facts = mz.gather()
    assert time.monotonic() - began < 2
    assert facts == {f"r{i}": {"id": f"inst_{i}"} for i in (0, 1, 2, 4, 5)}
