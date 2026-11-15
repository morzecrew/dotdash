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
        self.creds = ["--credentials-file", net.credentials] if net.credentials else []
        self.roster = str(roster)
        self.common = ["--target", net.target, "--expect", self.roster, *self.creds]

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
        """The facts of every server, relay and canary that joined, by name."""
        facts = {}
        for m in [*self.net.server, *self.net.relay, *self.net.canary]:
            if m.joined and (f := self.facts(m)) is not None:
                facts[m.name] = f
        return facts

    def rows(self) -> dict:
        """Each joined machine's own fleet row, by name, where its signature
        verifies: its age, whether it missed three hourly publishes (stale), and
        how many of its services run. What a burnt verdict needs to tell a
        machine blocked on the way from one that is down."""
        r = self.run("fleet", "ls", self.net.target, "--expect", self.roster, "--stale-after", "3h", "--json", *self.creds)
        try:
            rows = json.loads(r.stdout)["data"]["rows"]
        except (ValueError, KeyError, TypeError):
            return {}
        names = {m.id: m.name for m in self.net.machines if m.id}
        out = {}
        for row in rows:
            name = names.get(row.get("installation_id"))
            if name and row.get("signature") == "verified" and isinstance(row.get("row"), dict):
                h = row["row"].get("health") or {}
                out[name] = {"age": row.get("age", "?"), "stale": bool(row.get("stale")), "services": h.get("services"),
                             "running": h.get("running"), "problem": h.get("problem", "")}
        return out

    def publish(self, m: Machine, doc: dict, dry_run: bool) -> subprocess.CompletedProcess:
        return self.run("state", "publish", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                        "--file", "-", "--key", self.net.key, *(["--dry-run"] if dry_run else []), stdin=to_yaml(doc))
