"""morzer, which carries documents to the machines and their facts back: its
roster of who joined, and `state facts` and `state publish` against the target."""

import json
import subprocess
import sys
from pathlib import Path

from .roster import KINDS, PRODUCTS, Machine, Network


def write_roster(path: Path, net: Network) -> None:
    """morzer's roster (--expect): the machines that joined, with their keys."""
    lines = ["# Written by dotdash-manager from network.toml; edits here are lost.", "schema: 1", "installations:"]
    for kind in KINDS:
        for m in getattr(net, kind):
            if m.id:
                lines += [f"  - product: {PRODUCTS[kind]}", f"    id: {m.id}"] + ([f"    key: {m.key}"] if m.key else [])
    path.write_text("\n".join(lines) + ("\n" if len(lines) > 3 else " []\n"))


def to_yaml(doc: dict) -> str:
    """A change document as block YAML, which morzer reads: every value a JSON
    string or list, both valid YAML in flow style."""
    lines = []
    for section, values in doc.items():
        lines.append(f"{section}:")
        lines += [f"  {name}: {json.dumps(value)}" for name, value in values.items()]
    return "\n".join(lines) + "\n"


class Morzer:
    def __init__(self, net: Network, roster: Path, binary: str):
        self.net, self.binary = net, binary
        self.common = ["--target", net.target, "--expect", str(roster)]
        if net.credentials:
            self.common += ["--credentials-file", net.credentials]

    def run(self, *args: str, stdin: str | None = None) -> subprocess.CompletedProcess:
        return subprocess.run([self.binary, *args], input=stdin, capture_output=True, text=True, check=False)

    def facts(self, m: Machine) -> dict | None:
        r = self.run("state", "facts", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                     "--identity", self.net.identity, "--json")
        if r.returncode != 0:
            return None
        try:
            return json.loads(json.loads(r.stdout)["data"]["facts"])
        except (ValueError, KeyError, TypeError):
            print(f"{m.name}: its facts are not the JSON its facts task prints; left out", file=sys.stderr)
            return None

    def gather(self) -> dict:
        """The facts of every server and relay that joined, by name."""
        facts = {}
        for m in [*self.net.server, *self.net.relay]:
            if m.joined and (f := self.facts(m)) is not None:
                facts[m.name] = f
        return facts

    def publish(self, m: Machine, doc: dict, dry_run: bool) -> subprocess.CompletedProcess:
        return self.run("state", "publish", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                        "--file", "-", "--key", self.net.key, *(["--dry-run"] if dry_run else []), stdin=to_yaml(doc))
