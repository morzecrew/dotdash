"""The dotdash-manager command: sync, status, report, rotate, adopt, join and joined."""

import copy
import hashlib
import json
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import typer

from . import Refused, adopt, health, join as joining, roster, rotate, state, traffic
from .morzer import Morzer, write_roster
from .render import render
from .report import report as report_lines
from .roster import Network

# A document lives 168 h (morzer's default): renew an unchanged one well before.
RENEW_AFTER = 3 * 86400

app = typer.Typer(
    help="A dotdash network from one roster, through morzer's desired state.",
    no_args_is_help=True,
    add_completion=False,
    pretty_exceptions_enable=False,
)


@dataclass
class Options:
    roster: Path
    morzer: str
    locked: bool = False

    @property
    def state(self) -> Path:
        return self.roster.with_name("dotdash-state.json")

    @property
    def morzer_roster(self) -> Path:
        return self.roster.with_name("roster.yaml")

    def open(self, dry_run: bool = False) -> tuple[Network, dict]:
        """The roster and the state, under the state's lock for the rest of the
        run, the state kept before anything goes out: a key published and then
        lost is a network to redo. A dry run publishes nothing, and keeps
        nothing."""
        net = roster.load(self.roster)
        if not self.locked:
            state.lock(self.state)
            self.locked = True
        st = state.load(self.state, net)
        if not dry_run:
            state.save(self.state, st)
        net = roster.with_joined(net, st.get("joined", {}))
        write_roster(self.morzer_roster, net)
        return net, st


@app.callback()
def options(
    ctx: typer.Context,
    roster_path: Annotated[Path, typer.Option("--roster", help="the roster")] = Path("network.toml"),
    morzer: Annotated[str, typer.Option(help="the morzer binary")] = "morzer",
) -> None:
    ctx.obj = Options(roster_path, morzer)


@app.command()
def sync(ctx: typer.Context, dry_run: Annotated[bool, typer.Option("--dry-run", help="everything but the writes")] = False) -> None:
    """Read facts, render every document, publish those that changed."""
    o: Options = ctx.obj
    net, st = o.open(dry_run)
    mz = Morzer(net, o.morzer_roster, o.morzer)
    now = int(time.time())
    facts = mz.gather(st.setdefault("facts", {}), now)
    before = copy.deepcopy(st.setdefault("health", {}))
    burnt, verdicts = health.judge(net, facts, st["health"], mz.rows())
    held, stands, more = health.spares(net, facts, st["health"], burnt)
    verdicts += more
    off, more = health.blocked(net, facts, st["health"], burnt)
    verdicts += more
    split, more = health.splits(net, st["health"], burnt)
    verdicts += more
    log = st.setdefault("events", [])
    log += health.events(before, st["health"], st.get("stands", {}), stands, now)
    del log[:-health.EVENTS]
    labels(net, st)
    st["stands"] = stands
    traffic.record(st.setdefault("traffic", {}), facts, now)
    # Yesterday's whole day and today's so far.
    verdicts += traffic.unusual(st["traffic"], since=traffic.day(now - 86400))
    if not dry_run:
        state.save(o.state, st)
    for v in verdicts:
        print(v)
    docs, waiting = render(net, st, facts, burnt | held, off, stands, split)
    # After render, which turns hello_split off where the last sync had it on.
    st["split"] = sorted(split)
    if not dry_run:
        state.save(o.state, st)
    failed = 0
    for m in net.machines:
        doc = docs.get(m.name)
        if doc is None:
            continue
        if not m.joined:
            print(f"{m.name}: not joined (no id and key); run join {m.name} and pipe its output to joined {m.name}")
            continue
        digest = hashlib.sha256(json.dumps(doc, sort_keys=True).encode()).hexdigest()
        last = st["published"].get(m.id, {})
        if last.get("digest") == digest and time.time() - last.get("at", 0) < RENEW_AFTER:
            print(f"{m.name}: unchanged")
            continue
        r = mz.publish(m, doc, dry_run)
        if r.returncode != 0:
            failed += 1
            print(f"{m.name}: publish failed: {(r.stderr or r.stdout).strip()}", file=sys.stderr)
            continue
        print(f"{m.name}: {'would publish' if dry_run else 'published'}")
        if not dry_run:
            st["published"][m.id] = {"digest": digest, "at": int(time.time())}
            state.save(o.state, st)
    for w in waiting:
        print(f"waiting: {w}")
    raise typer.Exit(1 if failed else 0)


def labels(net: Network, st: dict) -> None:
    """The roster's provider and address_since of each server and relay into the
    state, kept after it leaves the roster as its events are, for report."""
    kept = st.setdefault("labels", {})
    for m in [*net.server, *net.relay]:
        if m.provider or m.address_since:
            kept[m.name] = {"provider": m.provider, "address_since": m.address_since and m.address_since.isoformat()}
        else:
            kept.pop(m.name, None)


@app.command()
def report(ctx: typer.Context) -> None:
    """How long each server and relay lasted before it burnt, how often and for
    how long it was burnt, which paths went off, how long each path lasted,
    lifetimes per provider, and each path's latency against the canaries' own
    network; from what sync logged. With device-traffic, the devices that
    moved far more than usual on a day."""
    o: Options = ctx.obj
    net, st = o.open()
    labels(net, st)
    for line in report_lines(net, st.get("events", []), int(time.time()), st.get("stands", {}), st.get("health", {}),
                             st.get("labels", {})):
        print(line)
    if st.get("traffic", {}).get("days"):
        print(f"\ndevices far above their usual day, the last {len(st['traffic']['days'])} days (device-traffic):")
        for line in traffic.unusual(st["traffic"]) or ["none"]:
            print(f"  {line}")


@app.command(name="rotate")
def rotate_key(
    ctx: typer.Context,
    step: Annotated[str | None, typer.Argument(help="start, swap or finish; none says where it stands")] = None,
    force: Annotated[bool, typer.Option("--force", help="swap with no canary through yet, or finish before the window ends")] = False,
) -> None:
    """Rotate the REALITY key with no device cut off: start puts a next key
    second on the servers and moves their canaries to it; swap, once one got
    through, makes it the key and keeps the old one second; finish, a week
    later, turns the old one off. Each is published by the next sync."""
    o: Options = ctx.obj
    net, st = o.open()
    now = int(time.time())
    if step is None:
        print(rotate.status(st, now))
        return
    if step == "start":
        said = rotate.start(st, now)
    elif step == "swap":
        facts = Morzer(net, o.morzer_roster, o.morzer).gather(st.setdefault("facts", {}), now)
        said = rotate.swap(st, net, facts, now, force)
    elif step == "finish":
        said = rotate.finish(st, now, force)
    else:
        raise Refused(f"rotate {step}: start, swap or finish")
    state.save(o.state, st)
    print(f"{said}\nrun sync to publish it")


@app.command()
def status(ctx: typer.Context) -> None:
    """What each machine applied and refused, and who has not joined."""
    o: Options = ctx.obj
    net = roster.load(o.roster)
    write_roster(o.morzer_roster, net)
    r = subprocess.run([o.morzer, "state", "ls", *Morzer(net, o.morzer_roster, o.morzer).common], check=False)
    for m in net.machines:
        if not m.joined:
            print(f"{m.name} ({m.kind}): not joined; run join {m.name}")
    raise typer.Exit(r.returncode)


@app.command(name="adopt")
def adopt_server(
    ctx: typer.Context,
    name: str,
    force: Annotated[bool, typer.Option("--force", help="even after the manager published its own keys")] = False,
) -> None:
    """A server that ran before the manager keeps its keys and its devices' ids:
    pipe in what ADOPT prints to run on it, before the first sync."""
    o: Options = ctx.obj
    net = roster.load(o.roster)
    m = net.find(name)
    if m is None or m.kind != "server":
        raise Refused(f"{name} is no [[server]] in {o.roster}")
    if sys.stdin.isatty():
        print(f"Run on {name}, as root, and pipe what it prints here:\n\n"
              f"  ssh <{name}> {shlex.quote('sudo sh -c ' + shlex.quote(adopt.COMMAND))} | dotdash-manager adopt {name}")
        return
    keys, ids, unnamed = adopt.parse(sys.stdin.read())
    net, st = o.open()
    if st["published"] and not force:
        raise Refused("the manager already published its own keys: adopting now changes them again on every machine; --force if that is meant")
    for line in adopt.take(st, net, keys, ids, unnamed):
        print(line)
    state.save(o.state, st)


@app.command()
def join(
    ctx: typer.Context,
    name: str,
    domain: Annotated[str | None, typer.Option(help="a server's domain, or a relay's own site's")] = None,
    site: Annotated[str | None, typer.Option(help="a relay's neighbour site, without --domain")] = None,
    entry_host: Annotated[str | None, typer.Option(help="the address devices reach a relay at, with --site")] = None,
    upstreams: Annotated[Path | None, typer.Option(help="a server's upstreams, one per line")] = None,
    recovery: Annotated[str | None, typer.Option(help="the age recipient of its backups; the identity's by default")] = None,
) -> None:
    """A script that brings a new machine named in the roster up and points it at
    the manager: pipe it to the machine and its output to `joined`."""
    o: Options = ctx.obj
    net, st = o.open()
    m = net.find(name)
    if m is None:
        raise Refused(f"add {name} to {o.roster} first, as [[server]], [[relay]], [[canary]] or [[client]] with its name")
    recipient = subprocess.run(["age-keygen", "-y", net.identity], capture_output=True, text=True, check=True).stdout.strip()
    doc = None
    if m.kind != "server":
        docs, waiting = render(net, st, Morzer(net, o.morzer_roster, o.morzer).gather(st.setdefault("facts", {})))
        doc = docs.get(m.name)
        if doc is None:
            raise Refused(f"{m.name} can't come up yet: " + "; ".join(w for w in waiting if w.startswith(m.name + ":")))
    sys.stdout.write(joining.script(
        m, net.target, net.authority, recipient, recovery or recipient, doc, domain, site, entry_host,
        upstreams.read_text() if upstreams else None,
        Path(net.credentials).read_text() if net.credentials else None))
    print(f"The script holds credentials: send it only to {m.name}, as root, and its output back here:\n"
          f"  dotdash-manager join {m.name} … | ssh <{m.name}> sudo sh | dotdash-manager joined {m.name}", file=sys.stderr)


@app.command()
def joined(ctx: typer.Context, name: str) -> None:
    """Passes on what a join script printed on the machine (stdin) and keeps the
    installation id and signing key its last line carries, for the next sync."""
    o: Options = ctx.obj
    if roster.load(o.roster).find(name) is None:
        raise Refused(f"{name} is not in {o.roster}")
    got = None
    for line in sys.stdin:
        if (g := joining.marker(line, name)) is not None:
            got = g
        else:
            sys.stdout.write(line)
            sys.stdout.flush()
    if got is None:
        raise Refused(f"{name}'s script stopped before its last line: nothing kept. Fix what it says above and run it again")
    # The lock only now: the script ran for minutes, and a timer's sync waits on it.
    _, st = o.open()
    st.setdefault("joined", {})[name] = {"id": got[0], "key": got[1]}
    state.save(o.state, st)
    print(f"{name}: joined as {got[0]}; the next sync gives it its document")


def main() -> None:
    try:
        app()
    except Refused as e:
        print(f"dotdash-manager: {e}", file=sys.stderr)
        sys.exit(78)
