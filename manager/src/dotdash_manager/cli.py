"""The dotdash-manager command: sync, status and join."""

import hashlib
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

import typer

from . import Refused, health, roster, state
from .morzer import Morzer, write_roster
from .render import render
from .roster import IMAGES, Network

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

    @property
    def state(self) -> Path:
        return self.roster.with_name("dotdash-state.json")

    @property
    def morzer_roster(self) -> Path:
        return self.roster.with_name("roster.yaml")

    def open(self) -> tuple[Network, dict]:
        """The roster and the state, the state kept before anything goes out: a
        key published and then lost is a network to redo."""
        net = roster.load(self.roster)
        st = state.load(self.state, net)
        state.save(self.state, st)
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
    net, st = o.open()
    mz = Morzer(net, o.morzer_roster, o.morzer)
    facts = mz.gather()
    burnt, verdicts = health.judge(net, facts, st.setdefault("health", {}))
    if not dry_run:
        state.save(o.state, st)
    for v in verdicts:
        print(v)
    docs, waiting = render(net, st, facts, burnt)
    failed = 0
    for m in net.machines:
        doc = docs.get(m.name)
        if doc is None:
            continue
        if not m.joined:
            print(f"{m.name}: not joined (no id and key in the roster); run join {m.name}")
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


@app.command()
def join(ctx: typer.Context, name: str) -> None:
    """What to run on a new machine already named in the roster: init with the
    values it needs to come up, sync towards this authority, and how to add it."""
    o: Options = ctx.obj
    net, st = o.open()
    m = net.find(name)
    if m is None:
        raise Refused(f"add {name} to {o.roster} first, as [[server]], [[relay]], [[canary]] or [[client]] with its name")
    recipient = subprocess.run(["age-keygen", "-y", net.identity], capture_output=True, text=True, check=True).stdout.strip()
    doc = None
    if m.kind != "server":
        docs, waiting = render(net, st, Morzer(net, o.morzer_roster, o.morzer).gather())
        doc = docs.get(m.name)
        if doc is None:
            raise Refused(f"{m.name} can't come up yet: " + "; ".join(w for w in waiting if w.startswith(m.name + ":")))
    print(f"On the new {m.kind} machine (scripts/bootstrap.sh installs what it needs):\n")
    if m.kind == "relay":
        print("# A relay of its own domain: --domain <it> --profile own-site in place of site and entry_host.")
    init = [f"sudo morzer init --release oci://ghcr.io/morzecrew/{IMAGES[m.kind]}:stable", "--recovery-recipient age1…",
            f"--sync-target {net.target} --sync-authority {net.authority}"]
    if m.kind == "server":
        init.append("--domain <its domain>")
    elif m.kind == "relay":
        init.append("--set site=<a site next to it> --set entry_host=<its IP>")
    init += [f"--set {k}={v}" for k, v in (doc or {}).get("parameters", {}).items()]
    print(" \\\n  ".join(init))
    if m.kind == "server":
        print("sudo morzer secret set upstreams    # its ways out, one line each")
    for key, value in (doc or {}).get("secrets", {}).items():
        print(f"sudo morzer secret set {key} <<'END'\n{value}\nEND")
    # Sync before the first apply, so its facts go out with the first row.
    cred = ""
    if net.credentials:
        print("sudo morzer secret set sync_target < <the target's credential document>")
        print("sudo morzer config set sync.credentials=sync_target")
        cred = " --credentials sync_target"
    print(f"sudo morzer config set sync.recipient={recipient} sync.enabled=true")
    print(f"sudo morzer backup target add {net.target}{cred}")
    print("sudo morzer apply\nsudo morzer fleet publish")
    print("sudo morzer fleet publish --dry-run --json | jq -r '.data.row.installation_id, .data.row.signing_key'")
    print(f"\nThen give {m.name} those two in {o.roster} (id = \"inst_…\", key = \"RW…\") and run sync.")
    if doc:
        print("\nThe secrets above are credentials: send them only to that machine.", file=sys.stderr)


def main() -> None:
    try:
        app()
    except Refused as e:
        print(f"dotdash-manager: {e}", file=sys.stderr)
        sys.exit(78)
