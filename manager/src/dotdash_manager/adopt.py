"""adopt: a server that ran before the manager keeps its keys and its devices'
ids, so devices keep their links and subscription URLs. The server prints
its shared keys and vless_clients (COMMAND, run on it over ssh), and the
manager takes them into its state in place of the ones it made."""

import base64
import binascii
import re
import uuid

from . import Refused
from .roster import Network
from .state import SHARED_KEYS, public_key

# Run as root on the server: each shared key and vless_clients, one line each,
# as its name and its rendered file's base64.
COMMAND = ("cd /run/dotdash/secrets && for f in " + " ".join([*SHARED_KEYS, "vless_clients"])
           + ' ; do b=$(base64 -w0 < "$f") || exit 1; printf "%s %s\\n" "$f" "$b"; done')


def parse(text: str) -> tuple[dict[str, str], dict[str, str], int, set[str]]:
    """The shared keys, the ids by device name, how many vless_clients lines
    name no device, and the devices whose line says desktop, from what COMMAND
    printed."""
    values = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        name, _, b64 = line.strip().partition(" ")
        if name not in SHARED_KEYS and name != "vless_clients":
            raise Refused(f"the server's output has a line for {name!r}, which is none of its shared keys: is it what `adopt` prints to run?")
        try:
            values[name] = base64.b64decode(b64, validate=True).decode()
        except (binascii.Error, UnicodeDecodeError):
            raise Refused(f"the server's {name} is not base64 of text: is it what `adopt` prints to run?") from None
    missing = [k for k in [*SHARED_KEYS, "vless_clients"] if k not in values]
    if missing:
        raise Refused(f"the server's output lacks {', '.join(missing)}: run all of what `adopt` prints, on the server, as root")
    keys = {k: values[k].strip() for k in SHARED_KEYS}
    for k, v in keys.items():
        if not v or any(c.isspace() for c in v):
            raise Refused(f"the server's {k} is empty or more than one word")
    try:
        public_key(keys["reality_key"])
    except (ValueError, binascii.Error):
        raise Refused("the server's reality_key is not an X25519 private key") from None
    ids, unnamed, desktops = {}, 0, set()
    for line in values["vless_clients"].splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        try:
            uuid.UUID(fields[0])
        except ValueError:
            raise Refused("a line of the server's vless_clients does not start with a UUID") from None
        if len(fields) < 2:
            unnamed += 1
        elif not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,31}", fields[1]):
            raise Refused(f"the server's vless_clients names {fields[1]!r}, which is not a name the roster can hold")
        elif fields[1] in ids:
            raise Refused(f"the server's vless_clients names {fields[1]} twice")
        else:
            ids[fields[1]] = fields[0]
            if fields[2:3] == ["desktop"]:
                desktops.add(fields[1])
    return keys, ids, unnamed, desktops


def take(state: dict, net: Network, keys: dict[str, str], ids: dict[str, str], unnamed: int,
         desktops: set[str] | frozenset[str] = frozenset()) -> list[str]:
    """Puts the server's keys and the ids of the roster's names into the state,
    and says what devices keep their links, which ones get new ones, which
    lose access at the next sync, and which desktops the roster doesn't call
    one, so they would get CDN links."""
    state["keys"].update(keys)
    names = net.clients_of("server")
    kept = [n for n in names if n in ids]
    for n in kept:
        state["ids"][n] = ids[n]
    said = [f"adopted: the server's keys; ids of {len(kept)} of the roster's {len(names)} names"]
    if new := [n for n in names if n not in ids]:
        said.append("new to the server, so new links: " + ", ".join(new))
    if gone := sorted(set(ids) - set(names)):
        said.append("on the server but not in the roster, losing access at the next sync unless added: " + ", ".join(gone))
    if unnamed:
        said.append(f"{unnamed} line(s) of the server's vless_clients name no device: they lose access at the next sync")
    if lacking := [n for n in kept if n in desktops and n not in net.desktops]:
        said.append("desktops on the server but not in the roster's desktops, getting CDN links at the next sync unless "
                    "added: " + ", ".join(lacking))
    return said
