"""morzer, which carries documents to the machines and their facts back: its
roster of who joined, and `state facts` and `state publish` against the target."""

import json
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .roster import KINDS, PRODUCTS, Machine, Network, _say

# morzer state facts runs at most this many at once: each waits on the target
# (a bucket, a host over SSH), not on this machine.
READERS = 8

# What a machine reports goes into every device's links and config, and onto
# the operator's terminal, so a machine that is not what it should be must
# reach neither. Every value a facts task prints is a name, a number or
# base64: a key or string holding whitespace (which would start another field
# or line of the servers' relays), a quote, a backslash or a brace (a device's
# JSON) or a control character (the terminal) is refused.
UNSAFE = re.compile(r'[\s"\\{}]')
Word = Annotated[str, Field(min_length=1)]
Port = Annotated[int, Field(ge=1, le=65535)]
# A canary's path names, which go on a relay's line as off= and into verdicts.
PathName = Annotated[str, Field(pattern=r"^[a-z0-9-]{1,32}$")]


class Facts(BaseModel):
    """The keys render, health and traffic read, each of the type they read
    it as. strict: "443" is no port; extra: a later release's keys pass."""
    model_config = ConfigDict(strict=True, extra="allow")


class Kcp(Facts):
    port: Port
    header: Word
    open: Word | None = None


class RelayKcp(Kcp):
    seed: Word


class OnPort(Facts):
    port: Port


class OwnSite(Facts):
    xhttp_path: Word


class Traffic(Facts):
    started: int
    devices: dict[str, int]


class TargetFacts(Facts):
    cert_days: int | None = None
    traffic: Traffic | None = None


class ServerFacts(TargetFacts):
    domain: Word
    https_port: Port
    public_key: Word
    encryption: Word
    xhttp_reality_port: Port | None = None
    kcp: Kcp | None = None
    hysteria2_port: Port | None = None


class RelayFacts(TargetFacts):
    entry_host: Word
    site: Word
    public_key: Word
    short_id: Word
    encryption: Word
    own_site: OwnSite | None = None
    kcp: RelayKcp | None = None
    hysteria2: OnPort | None = None
    cdn_hosts: list[Word] | None = None
    cdn_path: Word | None = None
    origin_host: Word | None = None
    cdn_only: bool | None = None
    name: Word | None = None
    via: bool | None = None


class CanaryFacts(Facts):
    server: Word
    address: Word
    checked_at: int
    paths: dict[PathName, bool]
    internet: bool | None = None


SHAPES: dict[str, type[Facts]] = {"server": ServerFacts, "relay": RelayFacts, "canary": CanaryFacts}


def _safe(s: str, where: str) -> str:
    if UNSAFE.search(s) or not s.isprintable():
        raise ValueError(f"{where} holds whitespace, a quote, a backslash, a brace or a control character")
    return s


def _clean(value, where: str):
    """value with every null left out, as if absent: no reader tells the two
    apart, and one looking for an object would crash on a null."""
    if isinstance(value, dict):
        # The key is checked before it names where its value is.
        return {_safe(k, where): _clean(v, f"{where}.{k}") for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [_clean(v, where) for v in value if v is not None]
    return _safe(value, where) if isinstance(value, str) else value


def check(kind: str, doc) -> tuple[dict | None, str]:
    """A server's, relay's or canary's facts, cleaned, or None and why they
    are refused. The reason names keys alone, never a value."""
    if not isinstance(doc, dict):
        return None, "not a JSON object"
    try:
        doc = _clean(doc, "facts")
        SHAPES[kind].model_validate(doc)
    except ValidationError as e:
        return None, "; ".join(_say(err) for err in e.errors())
    except ValueError as e:
        return None, str(e)
    return doc, ""


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

    def facts(self, m: Machine) -> tuple[dict | None, str]:
        """A machine's facts (check), or None and why there are none."""
        r = self.run("state", "facts", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                     "--identity", self.net.identity, "--json")
        if r.returncode != 0:
            return None, f"no facts read: {(r.stderr or r.stdout).strip()}"
        try:
            doc = json.loads(json.loads(r.stdout)["data"]["facts"])
        except (ValueError, KeyError, TypeError):
            return None, "its facts are not the JSON its facts task prints"
        f, why = check(m.kind, doc)
        return f, why and f"its facts are refused: {why}"

    def gather(self) -> dict:
        """The facts of every server, relay and canary that joined, by name,
        read READERS at a time."""
        joined = [m for m in [*self.net.server, *self.net.relay, *self.net.canary] if m.joined]
        with ThreadPoolExecutor(READERS) as pool:
            read = list(pool.map(self.facts, joined))
        out = {}
        for m, (f, why) in zip(joined, read, strict=True):
            if f is None:
                print(f"{m.name}: {why}; left out", file=sys.stderr)
            else:
                out[m.name] = f
        return out

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
                h = row["row"].get("health")
                h = h if isinstance(h, dict) else {}
                # The machine writes its own row: only numbers reach a verdict.
                count = lambda v: v if type(v) is int else None
                out[name] = {"age": row.get("age", "?"), "stale": bool(row.get("stale")),
                             "services": count(h.get("services")), "running": count(h.get("running")),
                             "problem": h.get("problem", "")}
        return out

    def publish(self, m: Machine, doc: dict, dry_run: bool) -> subprocess.CompletedProcess:
        return self.run("state", "publish", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                        "--file", "-", "--key", self.net.key, *(["--dry-run"] if dry_run else []), stdin=to_yaml(doc))
