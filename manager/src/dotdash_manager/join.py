"""join: a script that brings a new machine up and points it at the manager,
run as root over ssh, whose last line (MARKER) carries the machine's
installation id and signing key back to `joined`."""

import json
import shlex

from pydantic import TypeAdapter, ValidationError

from . import Refused
from .roster import IMAGES, PRODUCTS, InstallationId, Machine, SigningKey

MARKER = "dotdash-joined"
END = "DOTDASH_END"
BOOTSTRAP = "https://morzecrew.github.io/dotdash/bootstrap.sh"


def _secret(name: str, value: str) -> str:
    if END in value.splitlines():
        raise Refused(f"{name} holds a line {END}, which ends the script's copy of it")
    return f"morzer secret set {name} <<'{END}'\n{value.rstrip(chr(10))}\n{END}"


def script(m: Machine, target: str, authority: str, recipient: str, recovery: str, doc: dict | None,
           domain: str | None = None, site: str | None = None, entry_host: str | None = None,
           upstreams: str | None = None, credentials: str | None = None) -> str:
    """The script, for `sh` as root on the machine. A fresh one is installed:
    a server needs its domain and upstreams, a relay its domain (of its own
    site) or a neighbour's site and its address, and comes up idle under its
    roster name, until its facts give the servers its relay/1 line. One
    installed already, as a network set up by hand has them, only starts
    following the manager, whose document brings the rest."""
    etc = f"/etc/{PRODUCTS[m.kind]}"
    init = ["morzer init", f"--release oci://ghcr.io/morzecrew/{IMAGES[m.kind]}:stable",
            f"--recovery-recipient {shlex.quote(recovery)}"]
    lacking = None
    if m.kind == "server":
        if domain and upstreams is not None:
            init.append(f"--domain {shlex.quote(domain)}")
        else:
            lacking = "--domain and --upstreams <file>"
    elif m.kind == "relay":
        # Its name and the nonce it makes at init are its relay/1 line's head,
        # which the servers derive its id from: its facts carry both.
        init.append(f"--set name={shlex.quote(m.name)}")
        if domain:
            init.append(f"--domain {shlex.quote(domain)} --profile own-site")
        elif site and entry_host:
            init.append(f"--set site={shlex.quote(site)} --set entry_host={shlex.quote(entry_host)}")
        else:
            lacking = "--domain (its own site's) or --site and --entry-host"
    init += [f"--set {shlex.quote(f'{k}={v}')}" for k, v in (doc or {}).get("parameters", {}).items()]
    if lacking:
        fresh = [f"echo {shlex.quote(f'join: {m.name} is not installed yet, and installing it needs join {lacking}')} >&2", "exit 1"]
    else:
        fresh = [" \\\n  ".join(init)]
        if upstreams is not None:
            fresh.append(_secret("upstreams", upstreams))
        fresh += [_secret(k, v) for k, v in (doc or {}).get("secrets", {}).items()]
    cred = ""
    follow = []
    backups = f"{target.rstrip('/')}/backups/{m.name}"
    if credentials is not None:
        follow += [_secret("sync_target", credentials), "morzer config set sync.credentials=sync_target"]
        cred = " --credentials sync_target"
    follow += [
        f"morzer config set sync.target={shlex.quote(target)} sync.authority={shlex.quote(authority)} "
        f"sync.recipient={shlex.quote(recipient)} sync.enabled=true",
        # Its backups under a prefix of its own: morzer keeps them one level
        # under a target's root and prunes all it finds there, so machines
        # sharing the root pruned each other's. One joined before kept them at
        # the root: that target goes, and the backups already there stay.
        f"morzer backup target list --json | grep -qF {shlex.quote(json.dumps(backups))} || "
        f"morzer backup target add {shlex.quote(backups)}{cred}",
        f"! morzer backup target list --json | grep -qF {shlex.quote(json.dumps(target))} || "
        f"morzer backup target remove {shlex.quote(target)}",
        # init names it on a fresh machine; one installed before joining may
        # have none, and its backups would then die with it.
        (f"morzer secret recipients list --json | grep -qF {shlex.quote(recovery)} || "
         f"morzer secret recipients add {shlex.quote(recovery)} --kind recovery"),
    ]
    lines = [
        "#!/bin/sh",
        f"# dotdash-manager join {m.name}: this {m.kind}, following the manager. As root.",
        "set -eu",
        f"command -v morzer >/dev/null || curl -fsSL {BOOTSTRAP} | bash",
        f"fresh=1; [ ! -e {etc} ] || fresh=0",
        'if [ "$fresh" = 1 ]; then',
        *fresh,
        "else",
        f"echo {shlex.quote(f'join: {PRODUCTS[m.kind]} is installed here already: its init and secrets are left as they are, and the manager' + chr(39) + 's document brings the rest')}",
        "fi",
        *follow,
        # Sync on before the first apply, so its facts go out with the first row.
        '[ "$fresh" = 0 ] || morzer apply',
        "morzer fleet publish",
        "row=$(morzer fleet publish --dry-run --json)",
        "field() { printf '%s\\n' \"$row\" | grep -o \"\\\"$1\\\": *\\\"[^\\\"]*\\\"\" | cut -d'\"' -f4; }",
        f"printf '{MARKER} %s %s %s\\n' {shlex.quote(m.name)} \"$(field installation_id)\" \"$(field signing_key)\"",
    ]
    return "\n".join(lines) + "\n"


def marker(line: str, name: str) -> tuple[str, str] | None:
    """The id and key a MARKER line for name carries; None for any other line."""
    fields = line.split()
    if len(fields) < 1 or fields[0] != MARKER:
        return None
    if len(fields) != 4 or fields[1] != name:
        raise Refused(f"the script's last line is for another machine, or incomplete: {line.strip()!r}")
    _, _, mid, key = fields
    try:
        return TypeAdapter(InstallationId).validate_python(mid), TypeAdapter(SigningKey).validate_python(key)
    except ValidationError:
        raise Refused(f"{name} printed no installation id and signing key: {line.strip()!r}") from None
