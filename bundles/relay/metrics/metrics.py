"""metrics.py <product> <role>=<url>...: the metrics profile's exporter.

Every minute, each named Xray's metrics endpoint (its config's "metrics",
/debug/vars, on 127.0.0.1 in the namespace this shares) gives its traffic per
inbound and per outbound and its observatory's verdicts, and this writes them,
in Prometheus' text format, to the node exporter's textfile directory
(/textfile) as dotdash-<product>-<role>.prom, written to a temporary name and
renamed into place, as morzer writes its own. After three minutes with no
answer it exits, so its restart joins a recreated Xray's namespace.

Never per device: the configs keep no user counters, and this reads none.
`--demo` checks itself.
"""

import json
import os
import sys
import time
import urllib.request

EVERY = 60
OUT = "/textfile"
GIVE_UP = 3

HELP = {
    "dotdash_xray_up": ("gauge", "1 when the Xray's metrics endpoint answered"),
    "dotdash_inbound_bytes_total": ("counter", "bytes through an inbound since the Xray started, by direction"),
    "dotdash_outbound_bytes_total": ("counter", "bytes through an outbound since the Xray started, by direction"),
    "dotdash_observatory_alive": ("gauge", "1 when the Xray's observatory last found the outbound alive"),
    "dotdash_observatory_delay_seconds": ("gauge", "the observatory's last delay through an alive outbound"),
    "dotdash_xray_heap_bytes": ("gauge", "the Go heap the Xray holds, beside its GOMEMLIMIT"),
}


def label(value) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def series(product: str, role: str, data: dict | None) -> dict[str, list[str]]:
    """Each metric's lines for one Xray, from its /debug/vars (None: no answer)."""
    out: dict[str, list[str]] = {name: [] for name in HELP}

    def add(name: str, value, **labels) -> None:
        labels = {"product": product, "role": role, **labels}
        out[name].append(name + "{" + ",".join(f'{k}="{label(v)}"' for k, v in labels.items()) + "} " + str(value))

    add("dotdash_xray_up", 0 if data is None else 1)
    if data is None:
        return out
    stats = data.get("stats") or {}
    for kind in ("inbound", "outbound"):
        for tag, counts in sorted((stats.get(kind) or {}).items()):
            for direction in ("uplink", "downlink"):
                if isinstance(counts.get(direction), int):
                    add(f"dotdash_{kind}_bytes_total", counts[direction], **{kind: tag, "direction": direction})
    for tag, status in sorted((data.get("observatory") or {}).items()):
        if not isinstance(status, dict):
            continue
        alive = bool(status.get("alive"))
        add("dotdash_observatory_alive", int(alive), outbound=tag)
        if alive and isinstance(status.get("delay"), int):
            add("dotdash_observatory_delay_seconds", status["delay"] / 1000, outbound=tag)
    heap = (data.get("memstats") or {}).get("HeapAlloc")
    if isinstance(heap, int):
        add("dotdash_xray_heap_bytes", heap)
    return out


def text(product: str, read: dict[str, dict | None]) -> str:
    """The textfile for every Xray's /debug/vars (None where it didn't answer)."""
    merged: dict[str, list[str]] = {name: [] for name in HELP}
    for role, data in read.items():
        for name, lines in series(product, role, data).items():
            merged[name] += lines
    lines = []
    for name, (kind, says) in HELP.items():
        if merged[name]:
            lines += [f"# HELP {name} {says}", f"# TYPE {name} {kind}", *merged[name]]
    return "\n".join(lines) + "\n"


def fetch(url: str) -> dict | None:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            return json.load(r)
    except (OSError, ValueError):
        return None


def write(name: str, body: str, where: str = OUT) -> None:
    path = os.path.join(where, f"dotdash-{name}.prom")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(body)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def main(product: str, targets: list[str]) -> None:
    named = dict(t.split("=", 1) for t in targets)
    name, missed = "-".join([product, *named]), 0
    while True:
        read = {role: fetch(url) for role, url in named.items()}
        write(name, text(product, read))
        missed = missed + 1 if all(v is None for v in read.values()) else 0
        if missed >= GIVE_UP:
            sys.exit(f"metrics.py: no answer from {', '.join(named)} in {GIVE_UP} tries")
        time.sleep(EVERY)


def demo() -> None:
    import tempfile

    xray = {"stats": {"inbound": {"reality": {"uplink": 10, "downlink": 2000}, "probe": {"uplink": 1}},
                      "outbound": {"gate": {"uplink": 12, "downlink": 2100}}, "user": {"x": {"uplink": 5}}},
            "observatory": {"upstream-a": {"alive": True, "delay": 120}, "upstream-b": {"alive": False, "delay": 99}},
            "memstats": {"HeapAlloc": 8388608}}
    body = text("dotdash", {"xray": xray, "gate": None})
    assert 'dotdash_inbound_bytes_total{product="dotdash",role="xray",inbound="reality",direction="downlink"} 2000' in body
    assert 'dotdash_outbound_bytes_total{product="dotdash",role="xray",outbound="gate",direction="uplink"} 12' in body
    assert 'dotdash_observatory_alive{product="dotdash",role="xray",outbound="upstream-b"} 0' in body
    assert 'dotdash_observatory_delay_seconds{product="dotdash",role="xray",outbound="upstream-a"} 0.12' in body
    assert "upstream-b\"} 0." not in body.split("delay_seconds")[-1]  # no delay for a dead outbound
    assert 'dotdash_xray_up{product="dotdash",role="gate"} 0' in body and "x\"" not in body  # no user counters
    assert body.count("# TYPE dotdash_xray_up gauge") == 1 and label('a"b\\') == 'a\\"b\\\\'
    with tempfile.TemporaryDirectory() as d:
        write("dotdash-xray", body, d)
        assert open(os.path.join(d, "dotdash-dotdash-xray.prom")).read() == body
        assert os.listdir(d) == ["dotdash-dotdash-xray.prom"]


if __name__ == "__main__":
    if sys.argv[1:] == ["--demo"]:
        demo()
    else:
        main(sys.argv[1], sys.argv[2:])
