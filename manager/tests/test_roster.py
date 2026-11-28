import pytest

from dotdash_manager import Refused
from dotdash_manager.roster import loads

HEAD = 'target = "t"\nkey = "k"\nidentity = "i"\nauthority = "a"\n'


G = '[[group]]\nname = "g"\n'


def test_a_minimal_roster_loads():
    net = loads(HEAD + G + 'devices = ["phone"]\n[[server]]\nname = "a"\nid = "inst_A"\nkey = "RWa"\n')
    assert [m.name for m in net.machines] == ["a"] and net.server[0].joined and net.direct is None
    assert net.group_of(net.server[0]) == "g" and net.devices == ["phone"] and net.clients_of("g") == ["phone"]


def test_groups_their_servers_and_the_relays_serving_them():
    net = loads(HEAD + '[[group]]\nname = "a"\ndevices = ["phone"]\n[[group]]\nname = "b"\ndevices = ["tv"]\n'
                '[[server]]\nname = "s"\ngroup = "b"\n[[relay]]\nname = "r1"\n[[relay]]\nname = "r2"\ngroups = ["b"]\n'
                '[[canary]]\nname = "c"\nwatches = "r2"\n')
    assert net.group_of("tv") == "b" and [s.name for s in net.servers_of("b")] == ["s"] and net.servers_of("a") == []
    assert net.groups_of(net.find("r1")) == ["a", "b"] and net.groups_of(net.find("r2")) == ["b"]
    assert net.clients_of("b") == ["tv", "canary-c"], "a canary is a device of its relay's first group with a server"
    net = loads(HEAD + '[[group]]\nname = "a"\n[[group]]\nname = "b"\n[[server]]\nname = "s"\ngroup = "b"\n'
                '[[relay]]\nname = "r1"\n[[canary]]\nname = "c"\nwatches = "r1"\n')
    assert net.group_of(net.canary[0]) == "b"


def test_devices_at_the_top_say_where_they_went():
    with pytest.raises(Refused, match=r"devices: a device belongs to a server group now: list them under \[\[group\]\]"):
        loads(HEAD + 'devices = ["phone"]\n')


@pytest.mark.parametrize(
    "bad",
    [
        'direct = "no"',  # not coerced to false
        'subscription = "yes"',
        'ipv6 = "maybe"',
        G + 'devices = ["relay-x"]',
        G + 'devices = ["phone", "phone"]',
        G + 'devices = ["phone"]\n[[group]]\nname = "h"\ndevices = ["phone"]',  # one device in two groups
        G + '[[group]]\nname = "g"',
        '[[group]]\nname = "a-b"',  # a dash would read as a tag prefix on a relay
        '[[group]]\nname = "1a"',
        G + '[[canary]]\nname = "c"\nwatches = "nobody"',
        G + '[[server]]\nname = "Big"',
        G + '[[server]]\nname = "a"\n[[relay]]\nname = "a"',
        G + '[[server]]\nname = "a"\nid = "nope"',
        G + '[[server]]\nname = "a"\ncdn_host = ["x"]',  # a mistyped field
        G + 'devices = ["phone"]\n[[client]]\nname = "home"\ndevice = "phone"',  # no subscription
        'pools = { a = ["laptop", "a b"] }',
        G + '[[server]]\nname = "a"\nid = "inst_A"\n[[relay]]\nname = "r1"\nid = "inst_A"',  # one installation, two machines
        '[[server]]\nname = "a"',  # no group to be in
        G + '[[group]]\nname = "h"\n[[server]]\nname = "a"',  # two: which?
        G + '[[server]]\nname = "a"\ngroup = "h"',
        '[[relay]]\nname = "r"',  # nothing to serve
        G + '[[relay]]\nname = "r"\ngroups = []',
        G + '[[relay]]\nname = "r"\ngroups = ["h"]',
        G + '[[relay]]\nname = "r"\ntunnel_group = "h"',
        G + '[[relay]]\nname = "r"\nserver_link = "xhttp"',
        G + '[[relay]]\nname = "abcdefghijklmnopqrstuvwxy"',  # past the relay's 24
        G + '[[relay]]\nname = "x"\nvia = ["nobody"]',
        G + '[[relay]]\nname = "x"\nvia = ["x"]',
        G + '[[relay]]\nname = "x"\nvia = ["y"]\n[[relay]]\nname = "y"\nvia = ["z"]\n[[relay]]\nname = "z"\nvia = ["x"]',
        # x carries g's devices through y, which doesn't serve g.
        G + '[[group]]\nname = "h"\n[[relay]]\nname = "x"\nvia = ["y"]\n[[relay]]\nname = "y"\ngroups = ["h"]',
        "not toml",
    ],
)
def test_refused(bad):
    with pytest.raises(Refused):
        loads(HEAD + bad)


def test_the_refusal_says_where():
    with pytest.raises(Refused, match=r"server\.0\.name: not 1 to 32 lowercase letters"):
        loads(HEAD + G + '[[server]]\nname = "Big"', "net.toml")
