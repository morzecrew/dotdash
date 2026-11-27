"""The dotdash-manager command: sync, status, link, renew, report, rotate, adopt, join and joined."""

import copy
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import typer

from . import Refused, adopt, health, join as joining, roster, rotate, state, traffic
from . import status as overview
from .morzer import Morzer, write_roster
from .render import applied_keys, clients_digest, kept_pools, render, subscription_urls
from .report import report as report_lines
from .roster import Network

# A document lives 168 h (morzer's default): renew an unchanged one well before.
RENEW_AFTER = 3 * 86400
# status --wait: machines pull every 15 minutes, then apply; and it asks again
# this often, two morzer calls each time.
WAIT = 20 * 60
POLL = 30

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
    new_state: bool = False
    lock: int | None = None

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
        nothing. No state while the roster names a joined machine is likelier
        a checkout the state wasn't copied to than a new network: a new state
        would give every server new keys, cutting every device off."""
        net = roster.load(self.roster)
        if self.lock is None:
            self.lock = state.lock(self.state)
        joined = [m.name for m in net.machines if m.joined]
        if joined and not self.new_state and not self.state.exists():
            raise Refused(f"no {self.state} beside the roster, which names {', '.join(joined)} joined: a new state "
                          "gives every server new keys, cutting every device off. Copy the state here, or --new-state "
                          "if new keys are meant")
        st = state.load(self.state, net)
        if not dry_run:
            state.save(self.state, st)
        net = roster.with_joined(net, st.get("joined", {}))
        write_roster(self.morzer_roster, net)
        return net, st

    def release(self) -> None:
        """Let the state's lock go, for a run that from here on only reads."""
        if self.lock is not None:
            os.close(self.lock)
            self.lock = None


@app.callback()
def options(
    ctx: typer.Context,
    roster_path: Annotated[Path, typer.Option("--roster", help="the roster")] = Path("network.toml"),
    morzer: Annotated[str, typer.Option(help="the morzer binary")] = "morzer",
    new_state: Annotated[bool, typer.Option(
        "--new-state", help="make a state though the roster names joined machines: new keys for every server")] = False,
) -> None:
    ctx.obj = Options(roster_path, morzer, new_state)


@app.command()
def sync(ctx: typer.Context, dry_run: Annotated[bool, typer.Option("--dry-run", help="everything but the writes")] = False) -> None:
    """Read facts, render every document, publish those that changed."""
    o: Options = ctx.obj
    net, st = o.open(dry_run)
    mz = Morzer(net, o.morzer_roster, o.morzer)
    now = int(time.time())
    facts = mz.gather(st.setdefault("facts", {}), now)
    before = copy.deepcopy(st.setdefault("health", {}))
    burnt, verdicts = health.judge(net, facts, st["health"], mz.rows(), now)
    held, stands, more = health.spares(net, facts, st["health"], burnt)
    verdicts += more
    off, more = health.blocked(net, facts, st["health"], burnt)
    verdicts += more
    split, more = health.splits(net, st["health"], burnt)
    verdicts += more
    log = st.setdefault("events", [])
    log += health.events(before, st["health"], st.get("stands", {}), stands, now,
                         {t.name for t in [*net.server, *net.relay]})
    del log[:-health.EVENTS]
    labels(net, st)
    st["stands"] = stands
    # The relays devices don't get, for link to give a device what the
    # servers do.
    st["out"] = sorted(burnt | held)
    traffic.record(st.setdefault("traffic", {}), facts, now)
    # Yesterday's whole day and today's so far.
    verdicts += traffic.unusual(st["traffic"], since=traffic.day(now - 86400))
    verdicts += health.certs(net, facts)
    for v in verdicts:
        print(v)
    docs, waiting = render(net, st, facts, burnt | held, off, stands, split)
    failed, holds = [], set()
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
            holds.add(m.name)
            continue
        r = mz.publish(m, doc, dry_run)
        if r.returncode != 0:
            failed.append(m.name)
            print(f"{m.name}: publish failed: {(r.stderr or r.stdout).strip()}", file=sys.stderr)
            continue
        print(f"{m.name}: {'would publish' if dry_run else 'published'}")
        holds.add(m.name)
        st["published"][m.id] = {"digest": digest, "at": int(time.time())}
        # What a relay's facts say of the device list it has, status compares with this.
        if "vless_clients" in doc.get("secrets", {}):
            st["published"][m.id]["clients"] = clients_digest(doc["secrets"]["vless_clients"])
    # Who was sent hello_split and via, for the next render to take them off
    # where they no longer hold, and to name them nowhere else.
    names = {m.name for m in net.machines}
    for key, has in (("split", split), ("via", {n for n, d in docs.items() if "via" in d.get("parameters", {})})):
        st[key] = sorted(sent(set(st.get(key, [])), holds, has) & names)
    # Once, at the end: the keys were kept before anything went out (open),
    # and the rest a sync that stops short reads again from the same facts.
    if not dry_run:
        state.save(o.state, st)
    for w in waiting:
        print(f"waiting: {w}")
    raise typer.Exit(1 if failed else 0)


def sent(had: set[str], holds: set[str], has: set[str]) -> set[str]:
    """The machines holding something after a sync: those it went to in a
    document that is now theirs (holds: published, or unchanged), and the
    rest as they were (had)."""
    return (had - holds) | (has & holds)


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
    moved far more than usual on a day. Then the certificates running out, by
    the facts the last sync kept."""
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
    if lines := health.certs(net, {n: k["facts"] for n, k in st.get("facts", {}).items()}):
        print("", *lines, sep="\n")


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
def status(
    ctx: typer.Context,
    wait: Annotated[bool, typer.Option("--wait", help="until every machine applied or refused its newest document")] = False,
    timeout: Annotated[int, typer.Option(help="how long --wait waits, in seconds")] = WAIT,
) -> None:
    """One line per machine: its release, what it did with its newest document,
    its health, how old its facts are and what its canaries found; then the
    topology. Exits 1 when a document is refused, a machine isn't following,
    its row is stale, its services are down or a relay's device list isn't
    the one sent, or --wait ran out."""
    o: Options = ctx.obj
    # As sync opens them: who joined is in the state, and roster.yaml is
    # written under the lock, never beside a sync writing it. Then the lock
    # goes: a timer's sync waiting behind --wait would hold back the very
    # document it waits for. Each look reads the state the last sync left;
    # a document published meanwhile is the newest, the one to wait for.
    net, st = o.open(dry_run=True)
    o.release()
    mz = Morzer(net, o.morzer_roster, o.morzer)
    end = time.monotonic() + timeout
    while True:
        lines, pending, bad = overview.machines(net, st, mz.rows(), mz.published(), int(time.time()))
        if not (wait and pending) or time.monotonic() >= end:
            break
        time.sleep(POLL)
        st = state.load(o.state, net)
    print(*lines, *overview.topology(net, st), sep="\n")
    raise typer.Exit(1 if bad or (wait and pending) else 0)


def device_urls(o: Options, net: Network, st: dict, device: str) -> list[str]:
    """A device's subscription URLs as the servers serve them, from the facts,
    the relays left out and the spares standing in at the last sync."""
    if device not in net.devices:
        raise Refused(f"{device} is not in {o.roster}'s devices")
    if not net.subscription:
        raise Refused("subscription = false: run `sudo morzer task run client-config --output -- "
                      f"{device}` on a server for its links")
    facts = {n: k["facts"] for n, k in st.get("facts", {}).items()}
    lead = next((facts[s.name] for s in applied_keys(net, st, facts)), None)
    if lead is None:
        raise Refused("no server has applied the manager's keys yet: run sync, and status --wait")
    out = set(st.get("out", []))
    urls = subscription_urls(net, st, facts, device, lead, out, kept_pools(net, facts, out, st.get("stands", {}))[0])
    if not urls:
        raise Refused(f"direct = false keeps the servers' URL out, and {device}'s pools give it no own-site relay")
    return urls


def show(urls: list[str], through: bool, qr: bool) -> None:
    """Each URL as client-config prints it, and with qr its QR code by
    qrencode, the URL on its stdin rather than in the process list."""
    if qr and not shutil.which("qrencode"):
        print("qrencode is not installed here: no QR codes", file=sys.stderr)
        qr = False
    for i, url in enumerate(urls):
        print(f"through the relay {url.split('/')[2]}: {url}" if through or i else url, flush=True)
        if qr:
            subprocess.run(["qrencode", "-t", "ANSIUTF8"], input=url, text=True, check=False)


@app.command()
def link(
    ctx: typer.Context,
    device: str,
    qr: Annotated[bool, typer.Option("--qr", help="each as a QR code too, by qrencode")] = False,
) -> None:
    """A device's subscription URLs, as client-config prints them: the
    server's unless direct = false, then through each own-site relay its pools
    give it. They are its credentials: printed here, kept nowhere."""
    o: Options = ctx.obj
    net, st = o.open(dry_run=True)
    # A device added since the last sync has an id only in this run's memory,
    # which no server has.
    if device in net.devices and device not in state.saved_ids(o.state):
        raise Refused(f"{device} has no id yet: run sync, which makes it and gives it to every server and relay")
    show(device_urls(o, net, st, device), net.direct is False, qr)


@app.command()
def renew(ctx: typer.Context, device: str) -> None:
    """A new id for a device whose link leaked: new links and subscription URL
    from the next sync, and its old ones let no one in once every server and
    relay applied it. Prints the new URLs."""
    o: Options = ctx.obj
    net, st = o.open()
    if device not in net.devices:
        raise Refused(f"{device} is not in {o.roster}'s devices")
    st["ids"][device] = state.new_id(st["ids"])
    state.save(o.state, st)
    print(f"{device}: a new id. Run sync and status --wait; its old links and URL stop once every server and relay "
          "applied it. Its new " + ("URLs:" if net.subscription else "links: client-config on a server, after the sync"))
    if net.subscription:
        show(device_urls(o, net, st, device), net.direct is False, False)


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
    text = sys.stdin.read()
    keys, ids, unnamed, desktops = adopt.parse(text)
    # A state made here is no hazard: the server's keys replace the new ones.
    o.new_state = True
    net, st = o.open()
    if st["published"] and not force:
        raise Refused("the manager already published its own keys: adopting now changes them again on every machine; --force if that is meant")
    for line in [*adopt.take(st, net, keys, ids, unnamed, desktops), *adopt.changes(net, m, adopt.settings(text))]:
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
    # Its own credential where the roster gives one, else the network's.
    creds = m.credentials or net.credentials
    sys.stdout.write(joining.script(
        m, net.target, net.authority, recipient, recovery or recipient, doc, domain, site, entry_host,
        upstreams.read_text() if upstreams else None, Path(creds).read_text() if creds else None))
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
    net, st = o.open()
    # The script run on a machine joined already, under another name.
    if other := next((m.name for m in net.machines if m.id == got[0] and m.name != name), None):
        raise Refused(f"{name}'s script ran on {other}'s installation ({got[0]}): nothing kept. Run it on {name}")
    st.setdefault("joined", {})[name] = {"id": got[0], "key": got[1]}
    state.save(o.state, st)
    print(f"{name}: joined as {got[0]}; the next sync gives it its document")


def main() -> None:
    try:
        app()
    except Refused as e:
        print(f"dotdash-manager: {e}", file=sys.stderr)
        sys.exit(78)
