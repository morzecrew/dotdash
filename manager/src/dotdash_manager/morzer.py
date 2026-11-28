"""morzer, which carries documents to the machines and their facts back: its
roster of who joined, and `state facts` and `state publish` against the target."""

import json
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Annotated, Any

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import Refused
from .roster import KINDS, PRODUCTS, Machine, Network, _say

# morzer state facts runs at most this many at once: each waits on the target
# (a bucket, a host over SSH), not on this machine.
READERS = 8
# How long a machine's last good facts stand in for a read that fails: a day
# of a target's outage, a timer's worth of retries, before its relays go.
KEEP = 24 * 3600
# How long one morzer call may take. Each waits on the target, a bucket or a
# host over SSH, and takes seconds; one hung there would hold the state's lock,
# and every timer's sync behind it, for good.
TIMEOUT = 120

# What a machine reports goes into every device's links and config, and onto
# the operator's terminal, so a machine that is not what it should be must
# reach neither. Every value a facts task prints is a name, a number or
# base64: a key or string holding whitespace (which would start another field
# or line of the servers' relays), a quote, a backslash or a brace (a device's
# JSON) or a control character (the terminal) is refused.
UNSAFE = re.compile(r'[\s"\\{}]')
Word = Annotated[str, Field(min_length=1)]
Port = Annotated[int, Field(ge=1, le=65535)]
# A canary's path names, which go in a relay's relay_flags as off= and into verdicts.
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


class GroupState(Facts):
    """A server group as a relay's gateway last found it: its state, whether
    each of its servers served the relay its device list, how many devices
    that lets in, the list's digest and its age in seconds."""
    # starting, live, down or refused; a later release's word passes.
    state: Word
    servers: dict[Word, bool] | None = None
    devices: Annotated[int, Field(ge=0)] | None = None
    digest: Annotated[str, Field(pattern=r"^[0-9a-f]{8}$")] | None = None
    list_age: int | None = None


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
    # A relay of the release with server groups carries both: its relay/1
    # line's head, which each server derives its id from. One before it, neither.
    name: Annotated[str, Field(pattern=r"^[A-Za-z0-9._-]{1,24}$")] | None = None
    nonce: Annotated[str, Field(pattern=r"^[0-9a-f]{16}$")] | None = None
    groups: dict[Annotated[str, Field(pattern=r"^[a-z][a-z0-9]{0,15}$")], GroupState] | None = None


class CanaryFacts(Facts):
    server: Word
    address: Word
    checked_at: int
    paths: dict[PathName, bool]
    # Each CDN in front of a relay, by its name, which _clean checks as a host.
    cdn: dict[Word, bool] | None = None
    internet: bool | None = None


SHAPES: dict[str, type[Facts]] = {"server": ServerFacts, "relay": RelayFacts, "canary": CanaryFacts}


def _safe(s: str, where: str) -> str:
    if UNSAFE.search(s) or not s.isprintable():
        raise ValueError(f"{where} holds whitespace, a quote, a backslash, a brace or a control character")
    return s


def _clean(value: Any, where: str) -> Any:
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


def word(value) -> str | None:
    """A string a machine wrote in its own row, kept only when it is a few
    plain words (a release, an age, a class, a name, a time): anything else
    would reach the operator's terminal."""
    return value if isinstance(value, str) and re.fullmatch(r"[\w.:+ -]{1,64}", value) else None


def _sync(block) -> dict | None:
    """A row's sync block (morzer's FleetSync), each field as status reads it:
    the serials applied and refused, the refusal's step, class and names, the
    last fetch's result, and the names waiting for the staged release."""
    if not isinstance(block, dict):
        return None
    words = lambda v: [w for w in map(word, v) if w][:32] if isinstance(v, list) else []

    def doc(d) -> dict | None:
        if not isinstance(d, dict) or type(d.get("serial")) is not int:
            return None
        return {"serial": d["serial"], "at": word(d.get("at")), "step": word(d.get("step")),
                "class": word(d.get("class")), "names": words(d.get("names"))}

    fetch = block.get("last_fetch")
    return {"enabled": block.get("enabled") is True, "applied": doc(block.get("applied")),
            "refused": doc(block.get("refused")), "fetch": word(fetch.get("result")) if isinstance(fetch, dict) else None,
            "pending": words(block.get("pending"))}


def write_roster(path: Path, net: Network) -> None:
    """morzer's roster (--expect): the machines that joined, with their keys."""
    lines = ["# Written by dotdash-manager from network.toml; edits here are lost.", "schema: 1", "installations:"]
    for kind in KINDS:
        for m in getattr(net, kind):
            if m.id:
                lines += [f"  - product: {PRODUCTS[kind]}", f"    id: {m.id}"] + ([f"    key: {m.key}"] if m.key else [])
    # Whole or not at all: status --wait reads it holding no lock.
    tmp = path.with_name(f".{path.name}.tmp")
    tmp.write_text("\n".join(lines) + ("\n" if len(lines) > 3 else " []\n"))
    tmp.replace(path)


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
        """morzer's answer; one that never comes is a failure after TIMEOUT,
        which every caller already handles as such."""
        try:
            return subprocess.run([self.binary, *args], input=stdin, capture_output=True, text=True, check=False,
                                  timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess([self.binary, *args], 124, "",
                                               f"morzer {' '.join(args[:2])} gave no answer in {TIMEOUT} s: "
                                               "is the target reachable?")

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

    def gather(self, kept: dict | None = None, now: int | None = None) -> dict:
        """The facts of every server, relay and canary that joined, by name,
        read READERS at a time. Where none come, the machine's last good facts
        stand in for up to KEEP: kept (the state's facts), each as {id, at,
        facts}, which this keeps current. A passing error, or a wrong identity
        file, would otherwise take a server or relay out of every document."""
        kept = {} if kept is None else kept
        now = int(time.time()) if now is None else now
        joined = [m for m in [*self.net.server, *self.net.relay, *self.net.canary] if m.joined]
        with ThreadPoolExecutor(READERS) as pool:
            read = list(pool.map(self.facts, joined))
        for name in set(kept) - {m.name for m in joined}:
            del kept[name]
        out = {}
        for m, (f, why) in zip(joined, read, strict=True):
            last = kept.get(m.name)
            if last and last["id"] != m.id:
                last = None  # another installation's
            if f is not None:
                out[m.name] = f
                kept[m.name] = {"id": m.id, "at": now, "facts": f}
            elif last and now - last["at"] <= KEEP:
                out[m.name] = last["facts"]
                print(f"{m.name}: {why}; its facts of {(now - last['at']) // 3600} h ago stand in, "
                      f"for {KEEP // 3600} h at most", file=sys.stderr)
            elif last:
                print(f"{m.name}: {why}; its last facts are {(now - last['at']) // 3600} h old, past {KEEP // 3600} h: "
                      "LEFT OUT of every document until a read succeeds", file=sys.stderr)
            else:
                print(f"{m.name}: {why}; left out", file=sys.stderr)
        return out

    def rows(self) -> dict:
        """Each joined machine's own fleet row, by name, where its signature
        verifies: its age, whether it missed three hourly publishes (stale), and
        how many of its services run. What a burnt verdict needs to tell a
        machine blocked on the way from one that is down. For status, also
        its release, the one staged, why its facts didn't refresh, and what
        it did with the authority's documents (sync)."""
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
                own = row["row"]
                h = own.get("health")
                h = h if isinstance(h, dict) else {}
                # The machine writes its own row: only numbers reach a verdict.
                count = lambda v: v if type(v) is int else None
                out[name] = {"age": word(row.get("age")) or "?", "stale": bool(row.get("stale")),
                             "services": count(h.get("services")), "running": count(h.get("running")),
                             "problem": h.get("problem", ""), "version": word(own.get("version")),
                             "staged": word(own.get("staged")), "facts_problem": word(own.get("facts_problem")),
                             "sync": _sync(own.get("sync"))}
        return out

    def published(self) -> dict[str, int]:
        """The serial of the newest document on the target for each joined
        machine, by name (state ls), which its row's sync says it applied or
        refused, or neither yet."""
        r = self.run("state", "ls", *self.common, "--json")
        try:
            rows = json.loads(r.stdout)["data"]["rows"]
        except (ValueError, KeyError, TypeError):
            raise Refused(f"morzer state ls gave no rows: {(r.stderr or r.stdout).strip()}") from None
        names = {m.id: m.name for m in self.net.machines if m.id}
        return {names[row["installation_id"]]: row.get("published", 0) for row in rows
                if row.get("installation_id") in names and type(row.get("published", 0)) is int}

    def publish(self, m: Machine, doc: dict, dry_run: bool) -> subprocess.CompletedProcess:
        return self.run("state", "publish", *self.common, "--product", PRODUCTS[m.kind], "--installation", m.id,
                        "--file", "-", "--key", self.net.key, *(["--dry-run"] if dry_run else []), stdin=to_yaml(doc))
