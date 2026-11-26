import hashlib
from pathlib import Path

import pytest

from dotdash_manager import Refused, state
from dotdash_manager.render import clients_digest, relay_line, render
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


def test_direct_false_takes_the_first_own_site_relay_the_devices_pools_give_it(st, facts):
    roster = lambda pools: loads(ROSTER.replace("subscription = true", "subscription = true\ndirect = false")
                                 .replace('pools = { a = ["laptop", "203.0.113.5"] }', pools) + '[[relay]]\nname = "r2"\n')
    own = {**RELAY, "own_site": {"xhttp_path": "X"}}
    two = {**own, "entry_host": "198.51.100.9", "site": "two.example.net", "cdn_hosts": []}
    render_ = lambda net, r2: render(net, {**st, "ids": {**st["ids"], "relay-r2": "id"}}, {**facts, "r1": own, "r2": r2})
    # phone is in no pool: it sees every relay, r1 first.
    docs, _ = render_(roster('pools = { a = ["laptop", "203.0.113.5"] }'), two)
    assert docs["home"]["secrets"]["subscription_url"] == f"https://www.example.net/{token(st, 'phone')}"
    # phone's pool holds r2; r1 is pool a's alone, which phone isn't in.
    pooled = roster('pools = { a = ["laptop", "203.0.113.5"], b = ["phone", "198.51.100.9"] }')
    docs, _ = render_(pooled, two)
    assert docs["home"]["secrets"]["subscription_url"] == f"https://two.example.net/{token(st, 'phone')}"
    # r2 without a site of its own: none phone sees fetches subscriptions.
    docs, waiting = render_(pooled, {k: v for k, v in two.items() if k != "own_site"})
    assert "home" not in docs and any(w.startswith("home: waits for an own-site relay that phone's pools give it")
                                      for w in waiting)


def test_servers_whose_ports_or_profiles_differ_are_said(net, st, facts):
    pbk = facts["a"]["public_key"]
    both = {**facts, "b": {**facts["a"], "domain": "b.example.net", "public_key": pbk}}
    assert not any(w.startswith("servers differ") for w in render(net, st, both)[1])
    kcp = {"port": 8447, "header": "dtls", "open": "none"}
    both = {**both, "a": {**both["a"], "kcp": kcp, "hysteria2_port": 443},
            "b": {**both["b"], "kcp": {**kcp, "open": "quic"}, "https_port": 8443}}
    said = [w for w in render(net, st, both)[1] if w.startswith("servers differ")]
    assert said == [("servers differ in https_port, kcp, hysteria2_port: each server's links name the others with its own, "
                     "so some are dead; give every server the same profiles and ports; relays take 443, a's")]
    # b not ready yet: nothing to compare.
    assert not any(w.startswith("servers differ") for w in render(net, st, {**both, "b": {**both["b"], "public_key": "old"}})[1])


def test_nothing_applied_yet(net, st):
    docs, waiting = render(net, st, {})
    assert set(docs) == {"a", "b"} and docs["a"]["unset"] == {"parameters": ["relays"]}
    assert docs["a"]["parameters"]["servers"] == "self"
    assert any(w.startswith("r1: waits") for w in waiting) and any(w.startswith("home: waits") for w in waiting)


def test_a_canary_on_a_server_gets_its_hysteria2_port(st, facts):
    net = loads(ROSTER.replace('watches = "r1"', 'watches = "a"'))
    docs, _ = render(net, st, facts)
    assert "dotdash_hysteria2_port" not in docs["c1"]["parameters"]
    docs, _ = render(net, st, {**facts, "a": {**facts["a"], "hysteria2_port": 8443}})
    assert docs["c1"]["parameters"]["dotdash_hysteria2_port"] == "8443"


def test_a_relay_line_carries_its_hysteria2_port_after_mkcp():
    f = {"entry_host": "203.0.113.5", "site": "r.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}, "kcp": {"port": 8447, "header": "dtls", "seed": "K"},
         "hysteria2": {"port": 443}, "cdn_hosts": ["c.example.net"]}
    assert relay_line(f, {"hysteria2"}) == ("203.0.113.5 r.example.net P S E own-site x kcp=8447,dtls,K hy2=443"
                                      " cdn=c.example.net off=hysteria2")


def test_a_relay_line_carries_its_cdn_path_after_its_cdns():
    f = {"entry_host": "203.0.113.5", "site": "r.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}, "cdn_hosts": ["c.example.net"], "cdn_path": "y", "cdn_only": True,
         "name": "edge-1"}
    assert relay_line(f) == ("203.0.113.5 r.example.net P S E own-site x cdn=c.example.net cdnpath=y cdn-only"
                             " name=edge-1")


def test_a_relay_line_carries_its_door_s_cdn_after_its_cdn_path():
    f = {"entry_host": "203.0.113.5", "site": "r.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}, "cdn_path": "y", "origin_host": "o.example.ru", "cdn_only": True}
    assert relay_line(f) == "203.0.113.5 r.example.net P S E own-site x cdnpath=y origin=o.example.ru cdn-only"


def test_a_relay_line_carries_its_name_before_what_the_manager_adds():
    f = {"entry_host": "203.0.113.5", "site": "s.example.org", "public_key": "P", "short_id": "S", "encryption": "E",
         "name": "edge-1"}
    assert relay_line(f, {"reality"}, split=True) == "203.0.113.5 s.example.org P S E name=edge-1 off=reality split"


def test_a_canary_on_a_relay_gets_its_hysteria2_port(net, st, facts):
    docs, _ = render(net, st, facts)
    assert "dotdash_hysteria2_port" not in docs["c1"]["parameters"]
    docs, _ = render(net, st, {**facts, "r1": {**RELAY, "own_site": {"xhttp_path": "x"}, "hysteria2": {"port": 443}}})
    assert docs["c1"]["parameters"]["dotdash_hysteria2_port"] == "443"
    assert docs["c1"]["parameters"]["dotdash_server"] == "www.example.net"


def test_a_canary_checks_a_relays_cdns_once_its_release_does(net, st, facts):
    r1 = {**RELAY, "own_site": {"xhttp_path": "x"}, "cdn_path": "y", "origin_host": "o.example.ru,alt.example.ru/e/t/s/"}
    # No facts yet: it installs a release that checks them.
    docs, _ = render(net, st, {**facts, "r1": r1})
    assert docs["c1"]["parameters"]["dotdash_cdn_hosts"] == "c.example.net"
    assert docs["c1"]["parameters"]["dotdash_origin_host"] == "o.example.ru,alt.example.ru/e/t/s/"
    assert docs["c1"]["secrets"]["dotdash_cdn_xhttp_path"] == "y"
    # A release from before them would refuse the document: none, and said.
    old = {"server": "www.example.net", "address": "203.0.113.5", "checked_at": 1, "paths": {"reality": True}}
    docs, waiting = render(net, st, {**facts, "r1": r1, "c1": old})
    assert "dotdash_cdn_hosts" not in docs["c1"]["parameters"] and "dotdash_cdn_xhttp_path" not in docs["c1"]["secrets"]
    assert "c1: its release predates CDN checks: update it to check r1's CDNs" in waiting
    # One that checks them, on a relay without a CDN path: none to check.
    docs, _ = render(net, st, {**facts, "c1": {**old, "cdn": {}}})
    assert docs["c1"]["parameters"]["dotdash_cdn_hosts"] == docs["c1"]["parameters"]["dotdash_origin_host"] == "none"
    # A CDN the roster gives a cdn_extra is left out, and said.
    net = loads(ROSTER.replace("subscription = true",
                               'subscription = true\ncdn_extra = { "alt.example.ru" = { uplinkHTTPMethod = "GET" } }'))
    docs, waiting = render(net, st, {**facts, "r1": r1})
    assert docs["c1"]["parameters"]["dotdash_origin_host"] == "o.example.ru"
    assert any(w.startswith("c1: checks none of r1's CDNs with a cdn_extra in the roster (alt.example.ru/e/t/s/)")
               for w in waiting)


def test_a_standby_relay_ends_its_line_with_standby(st, facts):
    net = loads(ROSTER.replace('key = "RWr"\n', 'key = "RWr"\nstandby = true\n'))
    docs, _ = render(net, st, facts)
    assert docs["a"]["parameters"]["relays"].endswith(" standby")
    assert relay_line(RELAY, standby=True).endswith("cdn=c.example.net standby")


def test_a_relay_goes_via_another_which_lets_it_in(st, facts):
    net = loads(ROSTER + '[[relay]]\nname = "x"\nvia = ["r1"]\n')
    st = state.load(Path("/nonexistent"), net)
    pbk = state.public_key(st["keys"]["reality_key"])
    facts = {**facts, "a": {**facts["a"], "public_key": pbk}}
    docs, waiting = render(net, st, facts)
    # x has no facts yet: a fresh install, which takes via from the start.
    x = docs["x"]
    assert x["parameters"]["via"] == "203.0.113.5 www.example.net P S E" and "unset" not in x
    assert x["parameters"]["via_link"] == "reality"
    # The reality leg takes no fingerprint: it is scoped to the xhttp leg.
    assert "via_fingerprint" not in x["parameters"]
    assert x["parameters"]["dotdash_servers"] == "a.example.net"
    names = lambda doc: [line.split()[1] for line in doc["secrets"]["vless_clients"].splitlines()]
    assert names(docs["r1"]) == ["phone", "laptop", "canary-c1", "relay-x"]
    assert names(x) == ["phone", "laptop", "canary-c1"]
    assert "relay-x" in names(docs["a"])

    # A release from before via says nothing of it: x waits rather than going to the servers.
    docs, waiting = render(net, st, {**facts, "x": {**RELAY, "entry_host": "198.51.100.9"}})
    assert "x" not in docs and "x: its release predates via: update it" in waiting
    # Off via again, one an earlier document gave via (the state's via) has it
    # unset; any other is never told of via, which its release may refuse.
    plain = loads(ROSTER + '[[relay]]\nname = "x"\n')
    docs, _ = render(plain, {**st, "via": ["x"]}, {**facts, "x": {**RELAY, "via": True}})
    assert docs["x"]["unset"] == {"parameters": ["via", "via_link", "via_fingerprint"]} and "via" not in docs["x"]["parameters"]
    for f in {**RELAY, "via": True}, RELAY:
        docs, _ = render(plain, st, {**facts, "x": f})
        assert "unset" not in docs["x"] and "via" not in docs["x"]["parameters"]
        assert "unset" not in docs["r1"]


def test_a_relay_waits_for_the_facts_of_the_relay_it_goes_via(st, facts):
    net = loads(ROSTER + '[[relay]]\nname = "x"\n[[relay]]\nname = "y"\nvia = ["x"]\n')
    st = state.load(Path("/nonexistent"), net)
    pbk = state.public_key(st["keys"]["reality_key"])
    docs, waiting = render(net, st, {**facts, "a": {**facts["a"], "public_key": pbk}})
    assert "y" not in docs and "y: goes via x, which has no facts yet" in waiting


def test_a_relay_goes_via_another_by_xhttp_through_its_own_site(st, facts):
    net = loads(ROSTER + '[[relay]]\nname = "x"\nvia = ["r1"]\nvia_link = "xhttp"\n')
    st = state.load(Path("/nonexistent"), net)
    pbk = state.public_key(st["keys"]["reality_key"])
    facts = {**facts, "a": {**facts["a"], "public_key": pbk}}
    docs, waiting = render(net, st, facts)
    assert "x" not in docs and "x: goes via r1 by XHTTP, which needs their own site" in waiting
    docs, _ = render(net, st, {**facts, "r1": {**RELAY, "own_site": {"xhttp_path": "abc"}}})
    assert docs["x"]["parameters"]["via"] == "203.0.113.5 www.example.net P S E own-site abc"
    assert docs["x"]["parameters"]["via_link"] == "xhttp"
    # The xhttp leg carries a fingerprint, defaulting to chrome.
    assert docs["x"]["parameters"]["via_fingerprint"] == "chrome"


def test_the_xhttp_via_leg_takes_a_server_shaped_fingerprint(st, facts):
    net = loads(ROSTER + '[[relay]]\nname = "x"\nvia = ["r1"]\nvia_link = "xhttp"\nvia_fingerprint = "none"\n')
    st = state.load(Path("/nonexistent"), net)
    pbk = state.public_key(st["keys"]["reality_key"])
    facts = {**facts, "a": {**facts["a"], "public_key": pbk},
             "r1": {**RELAY, "own_site": {"xhttp_path": "abc"}}}
    docs, _ = render(net, st, facts)
    assert docs["x"]["parameters"]["via_fingerprint"] == "none"


def test_a_desktop_ends_its_line_with_desktop_on_servers_and_relays(st, facts):
    net = loads(ROSTER.replace('devices = ["phone", "laptop"]', 'devices = ["phone", "laptop"]\ndesktops = ["laptop"]'))
    docs, _ = render(net, st, facts)
    for doc in docs["a"], docs["r1"]:
        lines = doc["secrets"]["vless_clients"].splitlines()
        assert lines[0].split()[1:] == ["phone"] and lines[1].split()[1:] == ["laptop", "desktop"]


def test_a_desktop_must_be_a_device():
    with pytest.raises(Refused, match="desktop 'tv' is not in devices"):
        loads(ROSTER.replace('devices = ["phone", "laptop"]', 'devices = ["phone", "laptop"]\ndesktops = ["tv"]'))


def test_cdn_extra_reaches_every_server_only_when_the_roster_says(st, facts):
    docs, _ = render(loads(ROSTER), st, facts)
    assert "cdn_extra" not in docs["a"]["parameters"]
    net = loads(ROSTER.replace("subscription = true", 'subscription = true\n'
                               'cdn_extra = { "alt.example.ru" = { uplinkHTTPMethod = "GET", xPaddingObfsMode = true } }'))
    docs, _ = render(net, st, facts)
    for s in "a", "b":
        assert docs[s]["parameters"]["cdn_extra"] == 'alt.example.ru {"uplinkHTTPMethod": "GET", "xPaddingObfsMode": true}'
    net = loads(ROSTER.replace("subscription = true", "subscription = true\ncdn_extra = {}"))
    assert render(net, st, facts)[0]["a"]["parameters"]["cdn_extra"] == "none"


def test_a_burnt_relays_origin_names_leave_the_pools_without_their_paths(st, facts):
    net = loads(ROSTER.replace('pools = { a = ["laptop", "203.0.113.5"] }',
                               'pools = { a = ["laptop", "o.example.ru", "alt.example.ru"] }'))
    r1 = {**RELAY, "own_site": {"xhttp_path": "x"}, "cdn_path": "y", "origin_host": "o.example.ru,alt.example.ru/e/t/s/"}
    docs, _ = render(net, st, {**facts, "r1": r1})
    assert "origin=o.example.ru,alt.example.ru/e/t/s/" in docs["a"]["parameters"]["relays"]
    docs, _ = render(net, st, {**facts, "r1": r1}, burnt={"r1"})
    assert docs["a"]["parameters"]["pools"] == "a laptop"


def test_the_device_digest_is_the_relays_and_relay_configs():
    # As tasks/entry.sh's and relay-config.sh's awk, sort and sha256sum give it, busybox's too.
    text = "# devices\nbbbb-2 laptop desktop\n\naaaa-1 phone\n  cccc-3\n#dddd-4 gone\n"
    assert clients_digest(text) == "8cb1dc12" and clients_digest("") == "e3b0c442"
