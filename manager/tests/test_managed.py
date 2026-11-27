"""Every name a document can carry is one its bundle lets a document manage:
morzer refuses a whole document naming any other, so the machine takes no
change at all."""

from pathlib import Path

from dotdash_manager import rotate, state
from dotdash_manager.render import render
from dotdash_manager.roster import loads

BUNDLES = Path(__file__).resolve().parents[2] / "bundles"
ROSTER = """
target = "t"
key = "k"
identity = "i"
authority = "a"
subscription = true
direct = false
devices = ["phone", "laptop"]
desktops = ["laptop"]
cdn_extra = { "edge.example.net" = { uplinkHTTPMethod = "GET" } }
pools = { p = ["phone", "203.0.113.5"] }
[[server]]
name = "a"
cdn_hosts = ["cdn.example.net"]
[[relay]]
name = "r1"
[[relay]]
name = "r2"
via = ["r1"]
via_link = "xhttp"
[[relay]]
name = "r3"
[[canary]]
name = "c1"
watches = "a"
[[canary]]
name = "c2"
watches = "r1"
[[client]]
name = "home"
device = "phone"
"""
RELAY = {"entry_host": "203.0.113.5", "site": "r1.example.net", "public_key": "P", "short_id": "S", "encryption": "E",
         "own_site": {"xhttp_path": "x"}, "kcp": {"port": 8447, "header": "dtls", "seed": "K"}, "hysteria2": {"port": 443},
         "cdn_hosts": ["c.example.net"], "cdn_path": "y", "origin_host": "o.example.org", "via": True}


RELAY_BEFORE_GATEWAY = {
    *(("parameters", n) for n in ("dotdash_servers", "dotdash_address", "dotdash_port", "dotdash_public_key", "via")),
    *(("secrets", n) for n in ("vless_clients", "dotdash_id", "dotdash_encryption", "dotdash_short_id")),
}


def managed(kind: str) -> dict[str, set[str]]:
    """The managed lists of the bundle's manifest, each one flow sequence."""
    block = (BUNDLES / kind / "manifest.yaml").read_text().split("\nmanaged:\n", 1)[1]
    out = {}
    for line in block.splitlines():
        if not line.startswith("  "):
            break
        key, _, names = line.strip().partition(":")
        out[key] = {n.strip() for n in names.strip().strip("[]").split(",") if n.strip()}
    return out


def test_every_name_a_document_carries_is_managed_by_its_bundle():
    net = loads(ROSTER)
    st = {**state.load(Path("/nonexistent"), net), "via": ["r3"], "split": ["a"]}
    pbk = state.public_key(st["keys"]["reality_key"])
    facts = {"a": {"domain": "a.example.net", "https_port": 443, "public_key": pbk, "encryption": "E",
                   "xhttp_reality_port": 8443, "kcp": {"port": 8447, "header": "dtls", "open": "quic"},
                   "hysteria2_port": 443},
             "r1": RELAY, "r2": {**RELAY, "entry_host": "203.0.113.6"}, "r3": {**RELAY, "entry_host": "203.0.113.7"}}
    docs = []
    for phase in "next", "done":
        st["rotation"] = {"phase": phase, "since": 0, "second": {k: st["keys"][k] for k in rotate.KEYS}}
        docs += [render(net, st, facts, split={"a"})[0], render(net, st, facts)[0], render(net, st, {})[0]]
    sent = set()
    for rendered in docs:
        for name, doc in rendered.items():
            kind = net.find(name).kind
            for section in "parameters", "secrets":
                sent |= {(kind, section, n) for n in [*doc.get(section, {}), *doc.get("unset", {}).get(section, [])]}
    # Each kind's every section is exercised, so a name added to render shows here.
    assert {(k, s) for k, s, _ in sent} >= {("server", "parameters"), ("server", "secrets"), ("relay", "parameters"),
                                            ("relay", "secrets"), ("canary", "parameters"), ("canary", "secrets"),
                                            ("client", "secrets")}
    unmanaged = sorted((k, s, n) for k, s, n in sent if n not in managed(k).get(s, set()))
    # The relay's names from before its gateway, which render sends until the
    # manager knows server groups (the relay gateway design's PR 8): a relay
    # from 0.19.0 on refuses such a document. Equal, so that PR drops this.
    assert {(s, n) for k, s, n in unmanaged if k == "relay"} == RELAY_BEFORE_GATEWAY
    unmanaged = [u for u in unmanaged if u[0] != "relay"]
    assert unmanaged == [], f"a machine refuses a document naming these, which its manifest's managed lacks: {unmanaged}"
