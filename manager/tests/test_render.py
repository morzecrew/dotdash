import hashlib
import json
import os
from pathlib import Path

import pytest

from dotdash_manager import Refused, state
from dotdash_manager.render import flags_line, relay_id, relay_line, render
from dotdash_manager.roster import loads

VECTORS = Path(__file__).resolve().parents[2] / ".github" / "tests" / "relay-id.json"
GOLDEN = Path(__file__).parent / "fixtures" / "render-two-groups.json"
ROSTER = """
target = "file:///tmp/t"
key = "a.key"
identity = "a.age"
authority = "RWQ"
subscription = true
desktops = ["laptop"]
pools = { p = ["laptop", "tablet", "203.0.113.5"] }
[[group]]
name = "a"
devices = ["phone", "laptop"]
[[group]]
name = "b"
devices = ["tablet"]
[[server]]
name = "a1"
group = "a"
id = "inst_A1"
key = "RWa"
[[server]]
name = "a2"
group = "a"
id = "inst_A2"
key = "RWb"
[[server]]
name = "b1"
group = "b"
id = "inst_B1"
key = "RWc"
[[relay]]
name = "r1"
id = "inst_R1"
key = "RWr"
[[relay]]
name = "r2"
id = "inst_R2"
key = "RWs"
groups = ["b"]
via = ["r1"]
tunnel_group = "b"
[[canary]]
name = "c1"
watches = "r1"
[[canary]]
name = "c2"
watches = "b1"
[[client]]
name = "home"
device = "phone"
"""
RELAY = {"entry_host": "203.0.113.5", "site": "r1.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}, "kcp": {"port": 8447, "header": "dtls", "open": "quic", "seed": "K"},
         "hysteria2": {"port": 443}, "cdn_hosts": ["c.example.net"], "name": "r1", "nonce": "0123456789abcdef"}
R2 = {**RELAY, "entry_host": "198.51.100.9", "site": "r2.example.net", "cdn_hosts": [], "name": "r2",
      "nonce": "fedcba9876543210"}


def fixed_state(net) -> dict:
    """A state of fixed keys and ids, so what render makes of it is the same
    every run."""
    hexes = lambda g, n: hashlib.sha256(f"{g}{n}".encode()).hexdigest()
    keys = {g: {"reality_key": state.b64url(bytes.fromhex(hexes(g, "rk"))), "vless_seed": hexes(g, "vs") * 2,
                "reality_short_id": hexes(g, "sid")[:16], "xhttp_path": hexes(g, "xp")[:32],
                "kcp_seed": hexes(g, "ks")[:32], "subscription_key": hexes(g, "sk"), "relay_seed": hexes(g, "rs")}
            for g in ("a", "b")}
    ids = {n: f"{i:08x}-0000-4000-8000-{i:012x}" for i, n in enumerate(["phone", "laptop", "tablet", "canary-c1",
                                                                         "canary-c2"], 1)}
    return {**state.load(Path("/nonexistent"), net), "keys": keys, "ids": ids, "passwords": {"home": "pw"}}


def server(st, group, domain, **more) -> dict:
    return {"domain": domain, "https_port": 443, "public_key": state.public_key(st["keys"][group]["reality_key"]),
            "encryption": f"enc-{group}", "name": group, **more}


@pytest.fixture
def net():
    return loads(ROSTER)


@pytest.fixture
def st(net):
    return fixed_state(net)


@pytest.fixture
def facts(st):
    return {"a1": server(st, "a", "a1.example.net", xhttp_reality_port=8443),
            "a2": server(st, "a", "a2.example.net", xhttp_reality_port=8443),
            "b1": server(st, "b", "b1.example.net"), "r1": RELAY, "r2": R2}


def test_two_groups_render_as_the_golden(net, st, facts):
    """Every document of a two-group network, and what waits: regenerate with
    DOTDASH_GOLDEN=1 after a change meant to alter them, and read the diff."""
    got = json.dumps(render(net, st, facts, burnt={"r1"}, off={"r2": {"mkcp"}}, split={"r2"}), indent=1, sort_keys=True) + "\n"
    if os.environ.get("DOTDASH_GOLDEN"):
        GOLDEN.write_text(got)
    assert got == GOLDEN.read_text()


def test_the_relay_id_is_the_images(net):
    """The shared vector, as xray-entrypoint relay-id and the server's
    relay-config derive it."""
    for v in json.loads(VECTORS.read_text())["vectors"]:
        assert relay_id(v["seed"], v["name"], v["nonce"]) == v["id"], v


def test_each_groups_servers_get_its_keys_its_devices_and_every_relay_serving_it(net, st, facts):
    docs, waiting = render(net, st, facts)
    a1, b1 = docs["a1"], docs["b1"]
    assert a1["parameters"]["name"] == "a" and b1["parameters"]["name"] == "b"
    assert a1["parameters"]["servers"] == "self,a2.example.net" and b1["parameters"]["servers"] == "self"
    assert a1["secrets"]["relay_seed"] == docs["a2"]["secrets"]["relay_seed"] == st["keys"]["a"]["relay_seed"]
    assert b1["secrets"]["reality_key"] == st["keys"]["b"]["reality_key"] != a1["secrets"]["reality_key"]
    # No relay in vless_clients: each comes in by the id its servers derive.
    names = lambda doc: [line.split()[1] for line in doc["secrets"]["vless_clients"].splitlines()]
    assert names(a1) == ["phone", "laptop", "canary-c1"] and names(b1) == ["tablet", "canary-c2"]
    assert a1["parameters"]["relays"] == relay_line(RELAY)
    assert b1["parameters"]["relays"] == f"{relay_line(RELAY)}\n{relay_line(R2)}"
    assert relay_line(RELAY) == ("relay/1 r1 0123456789abcdef 203.0.113.5 r1.example.net P S E xhttp=x kcp=8447,dtls,K,quic "
                                 "hy2=443 cdn=c.example.net")
    # Another group's devices are no pool members here.
    assert a1["parameters"]["pools"] == "p laptop 203.0.113.5" and b1["parameters"]["pools"] == "p tablet 203.0.113.5"
    assert "relay_flags" not in a1["parameters"] and a1["unset"] == {"parameters": ["relay_flags"]}
    assert waiting == []


def test_a_relay_gets_a_server_line_per_group_it_serves_with_its_id_there(net, st, facts):
    docs, _ = render(net, st, facts)
    r1, r2 = docs["r1"], docs["r2"]
    a, b = r1["secrets"]["servers"].splitlines()
    pbk = state.public_key(st["keys"]["a"]["reality_key"])
    rid = relay_id(st["keys"]["a"]["relay_seed"], "r1", "0123456789abcdef")
    assert a == (f"server/1 a a1.example.net,a2.example.net 443 {pbk} {st['keys']['a']['reality_short_id']} enc-a {rid} "
                 f"xr=8443,{st['keys']['a']['xhttp_path']}")
    assert b.startswith("server/1 b b1.example.net 443 ") and b.endswith(relay_id(st["keys"]["b"]["relay_seed"], "r1", "0123456789abcdef"))
    assert rid != relay_id(st["keys"]["b"]["relay_seed"], "r1", "0123456789abcdef")
    # Narrowed to b: its line alone, through r1 (via, a secret of relay/1 lines).
    assert r2["secrets"]["servers"].startswith("server/1 b ") and len(r2["secrets"]["servers"].splitlines()) == 1
    assert r2["secrets"]["via"] == relay_line(RELAY)
    assert r2["parameters"] == {"ipv6": "allow", "server_link": "reality", "via_link": "reality", "via_fingerprint": "chrome",
                                "tunnel_group": "b"}
    assert r1["unset"] == {"secrets": ["via"], "parameters": ["tunnel_group"]}
    assert not any(n.startswith("dotdash_") or n == "vless_clients" for doc in (r1, r2) for n in [*doc["parameters"], *doc["secrets"]])


def test_a_relay_narrowed_to_some_groups_is_in_their_relays_alone(st, facts):
    net = loads(ROSTER.replace('[[relay]]\nname = "r1"\n', '[[relay]]\nname = "r1"\ngroups = ["a"]\n')
                .replace('groups = ["b"]\nvia = ["r1"]\n', 'groups = ["b"]\n'))
    docs, _ = render(net, st, facts)
    assert docs["a1"]["parameters"]["relays"] == relay_line(RELAY) and docs["b1"]["parameters"]["relays"] == relay_line(R2)
    assert [line.split()[1] for line in docs["r1"]["secrets"]["servers"].splitlines()] == ["a"]
    # The canary watching r1 is a device of r1's first group, a.
    assert "canary-c1" in docs["a1"]["secrets"]["vless_clients"] and "canary-c1" not in docs["b1"]["secrets"]["vless_clients"]


def test_a_burnt_relay_stays_in_relays_with_every_path_off(net, st, facts):
    """Out of relays, a relay is out of its id there: its canaries could never
    get through again. So devices lose its links by relay_flags alone."""
    docs, _ = render(net, st, facts, burnt={"r1"}, off={"r2": {"cdn:x.example.net"}}, split={"r2"})
    assert docs["a1"]["parameters"]["relays"] == relay_line(RELAY)
    assert docs["a1"]["parameters"]["relay_flags"] == "r1 off=cdn:c.example.net,hysteria2,mkcp,reality,xhttp"
    assert docs["b1"]["parameters"]["relay_flags"].splitlines()[1] == "r2 off=cdn:x.example.net split"
    assert docs["a1"]["parameters"]["pools"] == "p laptop" and "r1" in docs
    assert flags_line(RELAY, set(), False, True) == "r1 standby" and flags_line(RELAY, set(), False, False) is None


def test_a_relay_from_before_relay_lines_waits_out_of_relays(net, st, facts):
    old = {k: v for k, v in RELAY.items() if k != "nonce"}
    docs, waiting = render(net, st, {**facts, "r1": old})
    assert "r1" not in docs and docs["a1"]["unset"]["parameters"][0] == "relays"
    assert "r1: its release predates relay/1 lines (no nonce in its facts): update it; it is in no group's relays until then" in waiting
    assert "r2" not in docs and "r2: goes via r1, which has no relay/1 line in its facts yet" in waiting


def test_two_relays_with_one_name_keep_the_first(net, st, facts):
    docs, waiting = render(net, st, {**facts, "r2": {**R2, "name": "R1"}})
    assert docs["b1"]["parameters"]["relays"] == relay_line(RELAY) and "r2" not in docs
    assert any(w.startswith("r2: its name, R1, is r1's too") for w in waiting)


def test_a_relay_waits_while_a_groups_servers_change_keys(net, st, facts):
    # b1 shows another key (a swap not applied yet): r1 keeps its document
    # rather than drop b's devices; a group with no facts yet is left out.
    docs, waiting = render(net, st, {**facts, "b1": {**facts["b1"], "public_key": "old"}})
    assert "r1" not in docs and "r1: waits for b's servers to apply its keys" in waiting
    assert "b1: has not applied the keys yet" in waiting and "c2: waits for b1" in waiting
    docs, waiting = render(net, st, {k: v for k, v in facts.items() if k != "b1"})
    assert [line.split()[1] for line in docs["r1"]["secrets"]["servers"].splitlines()] == ["a"]
    assert "r1: b has no server with facts yet" in waiting and "r2" not in docs


def test_ids_xray_takes_for_one_go_out_to_no_one_across_groups(net, st, facts):
    phone = st["ids"]["phone"]
    with pytest.raises(Refused, match="phone and tablet have ids that differ only in bytes 6 and 7"):
        render(net, {**st, "ids": {**st["ids"], "tablet": phone[:14] + "ffff" + phone[18:]}}, facts)


def test_a_client_machine_gets_its_groups_url(net, st, facts):
    docs, _ = render(net, st, facts)
    token = hashlib.sha256(f"{st['keys']['a']['subscription_key']}:{st['ids']['phone']}".encode()).hexdigest()[:32]
    assert docs["home"]["secrets"]["subscription_url"] == f"https://a1.example.net/{token}"


def test_direct_false_sends_client_machines_through_an_own_site_relay_of_their_group(st, facts):
    net = loads(ROSTER.replace("subscription = true", "subscription = true\ndirect = false"))
    docs, _ = render(net, st, facts)
    token = hashlib.sha256(f"{st['keys']['a']['subscription_key']}:{st['ids']['phone']}".encode()).hexdigest()[:32]
    assert docs["a1"]["parameters"]["direct"] == "false"
    assert docs["home"]["secrets"]["subscription_url"] == f"https://r1.example.net/{token}"
    # r1 burnt: r2 serves b alone, so phone has no relay to fetch through.
    docs, waiting = render(net, st, facts, burnt={"r1"})
    assert "home" not in docs and any(w.startswith("home: waits for an own-site relay") for w in waiting)


def test_a_groups_servers_whose_ports_or_profiles_differ_are_said(net, st, facts):
    said = [w for w in render(net, st, {**facts, "a2": {**facts["a2"], "https_port": 8443}})[1] if "differ" in w]
    assert said == [("a's servers differ in https_port: each server's links name the others with its own, so some are dead; "
                     "give every server the same profiles and ports; relays take 443, a1's")]
    # Groups are compared within, never with each other.
    assert not any("differ" in w for w in render(net, st, facts)[1])


def test_nothing_applied_yet(net, st):
    docs, waiting = render(net, st, {})
    assert set(docs) == {"a1", "a2", "b1"} and docs["a1"]["unset"] == {"parameters": ["relays", "relay_flags"]}
    assert docs["a1"]["parameters"]["servers"] == "self"
    assert "r1: no facts yet" in waiting and any(w.startswith("home: waits") for w in waiting)


def test_a_canary_on_a_server_checks_its_groups_keys(net, st, facts):
    docs, _ = render(net, st, {**facts, "b1": {**facts["b1"], "hysteria2_port": 8443}})
    c2 = docs["c2"]
    assert c2["parameters"]["dotdash_public_key"] == state.public_key(st["keys"]["b"]["reality_key"])
    assert c2["secrets"]["dotdash_xhttp_path"] == st["keys"]["b"]["xhttp_path"] and c2["secrets"]["dotdash_id"] == st["ids"]["canary-c2"]
    assert c2["parameters"]["dotdash_hysteria2_port"] == "8443"


def test_a_canary_on_a_relay_gets_its_paths(net, st, facts):
    c1 = render(net, st, facts)[0]["c1"]
    assert c1["parameters"]["dotdash_address"] == "203.0.113.5" and c1["parameters"]["dotdash_kcp_open"] == "quic"
    assert c1["parameters"]["dotdash_hysteria2_port"] == "443" and c1["secrets"]["dotdash_kcp_seed"] == "K"
    assert c1["secrets"]["dotdash_xhttp_path"] == "x"


def test_a_canary_checks_a_relays_cdns_once_its_release_does(net, st, facts):
    r1 = {**RELAY, "cdn_path": "y", "origin_host": "o.example.org,alt.example.org/e/t/s/"}
    # No facts yet: it installs a release that checks them.
    docs, _ = render(net, st, {**facts, "r1": r1})
    assert docs["c1"]["parameters"]["dotdash_cdn_hosts"] == "c.example.net"
    assert docs["c1"]["parameters"]["dotdash_origin_host"] == "o.example.org,alt.example.org/e/t/s/"
    assert docs["c1"]["secrets"]["dotdash_cdn_xhttp_path"] == "y"
    # A release from before them would refuse the document: none, and said.
    old = {"server": "r1.example.net", "address": "203.0.113.5", "checked_at": 1, "paths": {"reality": True}}
    docs, waiting = render(net, st, {**facts, "r1": r1, "c1": old})
    assert "dotdash_cdn_hosts" not in docs["c1"]["parameters"] and "dotdash_cdn_xhttp_path" not in docs["c1"]["secrets"]
    assert "c1: its release predates CDN checks: update it to check r1's CDNs" in waiting
    # A CDN the roster gives a cdn_extra is left out, and said.
    net = loads(ROSTER.replace("subscription = true",
                               'subscription = true\ncdn_extra = { "alt.example.org" = { uplinkHTTPMethod = "GET" } }'))
    docs, waiting = render(net, st, {**facts, "r1": r1})
    assert docs["c1"]["parameters"]["dotdash_origin_host"] == "o.example.org"
    assert any(w.startswith("c1: checks none of r1's CDNs with a cdn_extra in the roster (alt.example.org/e/t/s/)")
               for w in waiting)


def test_a_relay_goes_via_another_by_xhttp_through_its_own_site(st, facts):
    net = loads(ROSTER.replace('via = ["r1"]\n', 'via = ["r1"]\nvia_link = "xhttp"\nvia_fingerprint = "none"\n'))
    docs, waiting = render(net, st, {**facts, "r1": {k: v for k, v in RELAY.items() if k != "own_site"}})
    assert "r2" not in docs and "r2: goes via r1 by XHTTP, which needs their own site" in waiting
    docs, _ = render(net, st, facts)
    assert docs["r2"]["parameters"]["via_link"] == "xhttp" and docs["r2"]["parameters"]["via_fingerprint"] == "none"
    assert " xhttp=x " in docs["r2"]["secrets"]["via"]


def test_a_relay_through_xhttp_with_reality_and_a_standby_one(st, facts):
    net = loads(ROSTER.replace('key = "RWr"\n', 'key = "RWr"\nserver_link = "xhttp-reality"\nstandby = true\n'))
    docs, _ = render(net, st, facts)
    assert docs["r1"]["parameters"]["server_link"] == "xhttp-reality"
    assert docs["a1"]["parameters"]["relay_flags"] == "r1 standby"


def test_a_desktop_ends_its_line_with_desktop(net, st, facts):
    lines = render(net, st, facts)[0]["a1"]["secrets"]["vless_clients"].splitlines()
    assert lines[0].split()[1:] == ["phone"] and lines[1].split()[1:] == ["laptop", "desktop"]


def test_cdn_extra_reaches_every_server_only_when_the_roster_says(net, st, facts):
    assert "cdn_extra" not in render(net, st, facts)[0]["a1"]["parameters"]
    net = loads(ROSTER.replace("subscription = true", 'subscription = true\n'
                               'cdn_extra = { "alt.example.org" = { uplinkHTTPMethod = "GET", xPaddingObfsMode = true } }'))
    docs, _ = render(net, st, facts)
    for s in "a1", "b1":
        assert docs[s]["parameters"]["cdn_extra"] == 'alt.example.org {"uplinkHTTPMethod": "GET", "xPaddingObfsMode": true}'


def test_a_burnt_relays_origin_names_leave_the_pools_without_their_paths(st, facts):
    net = loads(ROSTER.replace('pools = { p = ["laptop", "tablet", "203.0.113.5"] }',
                               'pools = { p = ["laptop", "o.example.org", "alt.example.org"] }'))
    r1 = {**RELAY, "cdn_path": "y", "origin_host": "o.example.org,alt.example.org/e/t/s/"}
    docs, _ = render(net, st, {**facts, "r1": r1})
    assert "origin=o.example.org,alt.example.org/e/t/s/" in docs["a1"]["parameters"]["relays"]
    docs, _ = render(net, st, {**facts, "r1": r1}, burnt={"r1"})
    assert docs["a1"]["parameters"]["pools"] == "p laptop"
    assert "cdn:alt.example.org,cdn:c.example.net,cdn:o.example.org," in docs["a1"]["parameters"]["relay_flags"]
