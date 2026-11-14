import hashlib
from pathlib import Path

import pytest

from dotdash_manager import state
from dotdash_manager.render import render
from dotdash_manager.roster import loads

ROSTER = """
target = "file:///tmp/t"
key = "a.key"
identity = "a.age"
authority = "RWQ"
subscription = true
devices = ["phone", "laptop"]
pools = { a = ["laptop", "203.0.113.5"] }
[[server]]
name = "a"
id = "inst_A"
key = "RWa"
[[server]]
name = "b"
id = "inst_B"
key = "RWb"
[[relay]]
name = "r1"
id = "inst_R"
key = "RWr"
[[canary]]
name = "c1"
watches = "r1"
[[client]]
name = "home"
device = "phone"
"""
RELAY = {"entry_host": "203.0.113.5", "site": "www.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "kcp": {"port": 8447, "header": "dtls", "open": "quic", "seed": "K"}, "cdn_hosts": ["c.example.net"]}


@pytest.fixture
def net():
    return loads(ROSTER)


@pytest.fixture
def st(net):
    return state.load(Path("/nonexistent"), net)


@pytest.fixture
def facts(st):
    pbk = state.public_key(st["keys"]["reality_key"])
    return {
        "a": {"domain": "a.example.net", "https_port": 443, "public_key": pbk, "encryption": "mlkem…"},
        "b": {"domain": "b.example.net", "https_port": 443, "public_key": "old", "encryption": "x"},
        "r1": RELAY,
    }


def token(st, device):
    return hashlib.sha256(f"{st['keys']['subscription_key']}:{st['ids'][device]}".encode()).hexdigest()[:32]


def test_servers(net, st, facts):
    docs, waiting = render(net, st, facts)
    sa, sb = docs["a"], docs["b"]
    assert sa["parameters"]["servers"] == "self,b.example.net" and sb["parameters"]["servers"] == "self,a.example.net"
    assert sa["parameters"]["relays"] == "203.0.113.5 www.example.net P S E kcp=8447,dtls,K,quic cdn=c.example.net"
    assert sa["parameters"]["pools"] == "a laptop 203.0.113.5" and "unset" not in sa
    assert sa["secrets"]["reality_key"] == st["keys"]["reality_key"]
    assert [line.split()[1] for line in sa["secrets"]["vless_clients"].splitlines()] == ["phone", "laptop", "canary-c1", "relay-r1"]
    assert "direct" not in sa["parameters"]
    assert "b: has not applied the keys yet" in waiting


def test_only_a_server_that_applied_the_keys_carries_relays_and_clients(net, st, facts):
    docs, _ = render(net, st, facts)
    r1 = docs["r1"]
    assert r1["parameters"]["dotdash_servers"] == "a.example.net"
    assert r1["parameters"]["dotdash_public_key"] == state.public_key(st["keys"]["reality_key"])
    assert r1["secrets"]["dotdash_id"] == st["ids"]["relay-r1"] and "relay-r1" not in r1["secrets"]["vless_clients"]
    c1 = docs["c1"]
    assert c1["parameters"]["dotdash_address"] == "203.0.113.5" and c1["parameters"]["dotdash_kcp_open"] == "quic"
    assert c1["secrets"]["dotdash_kcp_seed"] == "K" and "dotdash_xhttp_path" not in c1["secrets"]
    assert docs["home"]["secrets"]["subscription_url"] == f"https://a.example.net/{token(st, 'phone')}"


def test_direct_false_sends_client_machines_through_an_own_site_relay(st, facts):
    net = loads(ROSTER.replace("subscription = true", "subscription = true\ndirect = false"))
    docs, waiting = render(net, st, facts)
    assert docs["a"]["parameters"]["direct"] == "false" and "home" not in docs
    assert any(w.startswith("home: waits for an own-site relay") for w in waiting)
    docs, _ = render(net, st, {**facts, "r1": {**RELAY, "own_site": {"xhttp_path": "X"}}})
    assert docs["home"]["secrets"]["subscription_url"] == f"https://www.example.net/{token(st, 'phone')}"


def test_nothing_applied_yet(net, st):
    docs, waiting = render(net, st, {})
    assert set(docs) == {"a", "b"} and docs["a"]["unset"] == {"parameters": ["relays"]}
    assert docs["a"]["parameters"]["servers"] == "self"
    assert any(w.startswith("r1: waits") for w in waiting) and any(w.startswith("home: waits") for w in waiting)
