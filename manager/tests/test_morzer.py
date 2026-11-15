import json
import subprocess

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
