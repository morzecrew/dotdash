from dotdash_manager.morzer import to_yaml, write_roster
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
