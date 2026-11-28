"""adopt: a server that ran before the manager keeps its keys and its devices'
ids, so devices keep their links and subscription URLs, and its relay_seed,
so relays keep their ids there. The server prints its shared keys and
vless_clients (COMMAND, run on it over ssh), and the manager takes them into
its group's in its state, in place of the ones it made."""

import base64
import binascii
import re
import uuid

from . import Refused
from .roster import Network
from .state import SHARED_KEYS, check_ids, public_key

# What the first sync sets on the server besides keys and devices. adopt reads
# them as the server has them, since a difference reaches every device.
SETTINGS = ("subscription", "cdn_hosts", "pools", "direct", "name")
# A server released before relay ids has no relay_seed: the manager's own goes.
OPTIONAL = ("relay_seed",)

# Run as root on the server: each shared key it has and vless_clients, one
# line each, as its name and its rendered file's base64; then each of SETTINGS
# morzer gives, as setting:<name> and its value's base64.
COMMAND = ("cd /run/dotdash/secrets && for f in " + " ".join([*SHARED_KEYS, "vless_clients"])
           + ' ; do [ -e "$f" ] || continue; b=$(base64 -w0 < "$f") || exit 1; printf "%s %s\\n" "$f" "$b"; done'
           + " ; for p in " + " ".join(SETTINGS)
           + ' ; do v=$(morzer --product dotdash config get "$p" 2>/dev/null)'
           + ' && printf "setting:%s %s\\n" "$p" "$(printf %s "$v" | base64 -w0)"; done; true')


def parse(text: str) -> tuple[dict[str, str], dict[str, str], int, set[str]]:
    """The shared keys, the ids by device name, how many vless_clients lines
    name no device, and the devices whose line says desktop, from what COMMAND
    printed."""
    values = {}
    for line in text.splitlines():
        if not line.strip():
            continue
        name, _, b64 = line.strip().partition(" ")
        if name.startswith("setting:"):
            continue
        if name not in SHARED_KEYS and name != "vless_clients":
            raise Refused(f"the server's output has a line for {name!r}, which is none of its shared keys: is it what `adopt` prints to run?")
        try:
            values[name] = base64.b64decode(b64, validate=True).decode()
        except (binascii.Error, UnicodeDecodeError):
            raise Refused(f"the server's {name} is not base64 of text: is it what `adopt` prints to run?") from None
    missing = [k for k in [*SHARED_KEYS, "vless_clients"] if k not in values and k not in OPTIONAL]
    if missing:
        raise Refused(f"the server's output lacks {', '.join(missing)}: run all of what `adopt` prints, on the server, as root")
    keys = {k: values[k].strip() for k in SHARED_KEYS if k in values}
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


def take(state: dict, net: Network, group: str, keys: dict[str, str], ids: dict[str, str], unnamed: int,
         desktops: set[str] | frozenset[str] = frozenset()) -> list[str]:
    """Puts the server's keys into its group's and the ids of the group's
    names into the state, and says what devices keep their links, which ones
    get new ones, which lose access at the next sync, and which desktops the
    roster doesn't call one, so they would get CDN links."""
    state["keys"][group].update(keys)
    names = net.clients_of(group)
    kept = [n for n in names if n in ids]
    for n in kept:
        state["ids"][n] = ids[n]
    check_ids(state["ids"])
    said = [f"adopted: the server's keys, as {group}'s; ids of {len(kept)} of {group}'s {len(names)} names"]
    if new := [n for n in names if n not in ids]:
        said.append("new to the server, so new links: " + ", ".join(new))
    gone = sorted(set(ids) - set(names))
    if relays := [n for n in gone if n.startswith("relay-")]:
        said.append("relays' clients of the release before, dropped at the next sync: relays come in by the ids the "
                    "servers derive for their relay/1 lines: " + ", ".join(relays))
    if gone := [n for n in gone if n not in relays]:
        said.append(f"on the server but not in {group}, losing access at the next sync unless added: " + ", ".join(gone))
    if unnamed:
        said.append(f"{unnamed} line(s) of the server's vless_clients name no device: they lose access at the next sync")
    if lacking := [n for n in kept if n in desktops and n not in net.desktops]:
        said.append("desktops on the server but not in the roster's desktops, getting CDN links at the next sync unless "
                    "added: " + ", ".join(lacking))
    return said


def settings(text: str) -> dict[str, str]:
    """The server's SETTINGS from what COMMAND printed, by name: only those
    morzer gave, as a release before one has none."""
    have = {}
    for line in text.splitlines():
        name, _, b64 = line.strip().partition(" ")
        if name.startswith("setting:") and name[8:] in SETTINGS:
            try:
                have[name[8:]] = base64.b64decode(b64, validate=True).decode().strip()
            except (binascii.Error, UnicodeDecodeError):
                raise Refused(f"the server's {name[8:]} is not base64 of text: is it what `adopt` prints to run?") from None
    return have


def changes(net: Network, server, have: dict[str, str]) -> list[str]:
    """What the first sync changes on the server beyond its keys and devices,
    each of which devices would otherwise find out: subscription URLs that
    stop, CDN links that go, other pools. And the order to join in."""
    hosts = lambda v: sorted(set(v.replace(",", " ").split()) - {"none"})
    pools = lambda text: {f[0]: sorted(f[1:]) for f in (line.split() for line in re.sub("#.*", "", text).splitlines()) if len(f) > 1}
    said = []
    if "subscription" in have and have["subscription"] != str(net.subscription).lower():
        said.append(f"subscription: the server has {have['subscription']}, the roster {str(net.subscription).lower()}, "
                    "which the next sync sets" + (": every device's subscription URL stops" if have["subscription"] == "true" else ""))
    if "cdn_hosts" in have and hosts(have["cdn_hosts"]) != sorted(server.cdn_hosts):
        said.append(f"cdn_hosts: the server has {','.join(hosts(have['cdn_hosts'])) or 'none'}, its [[server]] "
                    f"{','.join(server.cdn_hosts) or 'none'}, which the next sync sets")
    if "pools" in have and pools(have["pools"]) != {p: sorted(m) for p, m in net.pools.items()}:
        said.append("pools: the server's differ from the roster's [pools], which the next sync sets")
    if net.direct is not None and have.get("direct") in ("true", "false") and have["direct"] != str(net.direct).lower():
        said.append(f"direct: the server has {have['direct']}, the roster {str(net.direct).lower()}, which the next sync sets")
    if have.get("name", "none") not in ("none", net.group_of(server)):
        said.append(f"name: the server has {have['name']}, its group {net.group_of(server)}, which the next sync sets: "
                    "its own links are named by it, and each relay's servers line for it changes with that sync")
    if net.relay:
        said.append("join the relays before this server: until a relay's facts are in, the server's document leaves "
                    "its line out of relays, and devices lose its links")
    return said
