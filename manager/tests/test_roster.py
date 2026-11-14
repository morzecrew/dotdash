import pytest

from dotdash_manager import Refused
from dotdash_manager.roster import loads

HEAD = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'


def test_a_minimal_roster_loads():
    net = loads(HEAD + 'devices = ["phone"]\n[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n')
    assert [m.name for m in net.machines] == ["a"] and net.server[0].joined and net.direct is None


@pytest.mark.parametrize(
    "bad",
    [
        'direct = "no"',  # not coerced to false
        'subscription = "yes"',
        'ipv6 = "maybe"',
        'devices = ["relay-x"]',
        'devices = ["phone", "phone"]',
        '[[canary]]\nname = "c"\nwatches = "nobody"',
        '[[server]]\nname = "Big"',
        '[[server]]\nname = "a"\n[[relay]]\nname = "a"',
        '[[server]]\nname = "a"\nid = "nope"',
        '[[server]]\nname = "a"\ncdn_host = ["x"]',  # a mistyped field
        'devices = ["phone"]\n[[client]]\nname = "home"\ndevice = "phone"',  # no subscription
        'pools = { a = ["laptop", "a b"] }',
        "not toml",
    ],
)
def test_refused(bad):
    with pytest.raises(Refused):
        loads(HEAD + bad)


def test_the_refusal_says_where():
    with pytest.raises(Refused, match=r"server\.0\.name: not 1 to 32 lowercase letters"):
        loads(HEAD + '[[server]]\nname = "Big"', "net.toml")
