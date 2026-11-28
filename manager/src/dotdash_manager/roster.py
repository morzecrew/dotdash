"""The roster, network.toml: the server groups and their devices, the servers,
relays, canaries and client machines."""

import re
import tomllib
from datetime import date
from pathlib import Path
from typing import Annotated, Any, ClassVar, Literal

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationError, model_validator

from . import Refused

KINDS = ("server", "relay", "canary", "client")
PRODUCTS = {"server": "dotdash", "relay": "dotdash-relay", "canary": "dotdash-canary", "client": "dotdash-client"}
IMAGES = {"server": "dotdash-server", "relay": "dotdash-relay", "canary": "dotdash-canary", "client": "dotdash-client"}


def _matching(pattern: str, says: str):
    def check(value: str) -> str:
        if not re.fullmatch(pattern, value):
            raise ValueError(says)
        return value

    return AfterValidator(check)


Name = Annotated[str, _matching(r"[a-z0-9][a-z0-9-]{0,31}", "not 1 to 32 lowercase letters, digits and dashes")]
# A server group's name, as the image takes it: its servers' name parameter,
# its Xray tag prefix on every relay and the @ suffix of its devices there.
GroupName = Annotated[str, _matching(r"[a-z][a-z0-9]{0,15}", "not 1 to 16 lowercase letters and digits, starting with a letter")]
# A relay's: its own name parameter, which join sets and its relay/1 line carries.
RelayName = Annotated[str, _matching(r"[a-z0-9][a-z0-9-]{0,23}", "not 1 to 24 lowercase letters, digits and dashes")]
InstallationId = Annotated[str, _matching(r"(inst|op)_[0-9A-Za-z]+", "not an installation id (inst_…)")]
SigningKey = Annotated[str, _matching(r"[A-Za-z0-9+/]+=*", "not a minisign public key (its single base64 line)")]
Host = Annotated[str, _matching(r"[A-Za-z0-9.:-]+", "not a device name or a host")]
Required = Annotated[str, Field(min_length=1)]


class Strict(BaseModel):
    # strict: "no" is not false; extra: a mistyped field is refused, not ignored.
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)


class Machine(Strict):
    kind: ClassVar[str]
    name: Name
    id: InstallationId | None = None
    key: SigningKey | None = None
    # morzer's credential document for the target, this machine's own, which
    # join hands it in place of the network's: one that reaches only its own
    # prefixes, so a seized relay can't touch the servers' objects.
    credentials: str | None = None

    @property
    def joined(self) -> bool:
        return self.id is not None and self.key is not None


class Target(Machine):
    """A server or relay, which canaries watch. provider and address_since are
    the operator's own record, read by nothing but report: who hosts it, under
    the operator's name for them, and since when its address is the one
    devices reach, so lifetimes add up per provider and per address age."""
    provider: Annotated[str, Field(min_length=1, max_length=64)] | None = None
    address_since: date | None = None


class Group(Strict):
    """Servers sharing keys, and the devices they let in: each group has keys,
    a relay_seed and an exit of its own, and its devices reach no other's."""
    name: GroupName
    devices: list[Name] = []


class Server(Target):
    kind: ClassVar[str] = "server"
    # Its [[group]]: unset, the roster's only one.
    group: GroupName | None = None
    cdn_hosts: list[str] = []


class Relay(Target):
    kind: ClassVar[str] = "relay"
    name: RelayName
    # The groups whose devices it carries, each to that group's servers:
    # unset, every group.
    groups: list[GroupName] | None = None
    # How it reaches the servers: REALITY, or XHTTP with REALITY where a
    # group's servers serve it (their xhttp-reality profile).
    server_link: Literal["reality", "xhttp-reality"] = "reality"
    # The group a cover app's tunnel_host goes through; unset, its first.
    tunnel_group: GroupName | None = None
    # A spare: installed, given its document and watched by its canaries like
    # any relay, but kept out of what devices get until a burnt relay's place
    # needs it (health.spares).
    spare: bool = False
    # Standby: in what devices get, but last, unchecked, and used only once
    # every other link fails (standby in the servers' relay_flags).
    standby: bool = False
    # Other relays this one goes through instead of the servers (its via):
    # they let it in by its id on each group, and the servers never see its
    # address. Each serves every group this one does.
    via: list[Name] = []
    # How it reaches them: REALITY, or XHTTP through their own sites.
    via_link: Literal["reality", "xhttp"] = "reality"
    # The TLS client hello the xhttp via leg shows: a browser, or none for
    # Xray's own Go TLS stack (server-shaped). Only affects via_link="xhttp".
    via_fingerprint: Literal[
        "chrome", "firefox", "safari", "edge", "ios", "android", "random", "none"
    ] = "chrome"


class Canary(Machine):
    """A device of one group: the group of the server it watches, or the
    first with a server that a relay it watches serves."""
    kind: ClassVar[str] = "canary"
    watches: str


class Client(Machine):
    kind: ClassVar[str] = "client"
    device: str


class Network(Strict):
    target: Required
    credentials: str | None = None
    key: Required
    identity: Required
    authority: Required
    subscription: bool = False
    ipv6: Literal["allow", "block"] = "allow"
    # None leaves each server's own setting: a server released before direct refuses it.
    direct: bool | None = None
    group: list[Group] = []
    # Devices that get no CDN link: "desktop" after their names in vless_clients.
    desktops: list[Name] = []
    # The XHTTP extra a CDN or gateway in front asks for, by its host: every
    # server's cdn_extra. None leaves each server's own: one released before
    # cdn_extra refuses it.
    cdn_extra: dict[Host, dict[str, Any]] | None = None
    pools: dict[Name, list[Host]] = {}
    server: list[Server] = []
    relay: list[Relay] = []
    canary: list[Canary] = []
    client: list[Client] = []

    @property
    def machines(self) -> list[Machine]:
        return [*self.server, *self.relay, *self.canary, *self.client]

    @property
    def devices(self) -> list[str]:
        return [d for g in self.group for d in g.devices]

    def find(self, name: str) -> Machine | None:
        return next((m for m in self.machines if m.name == name), None)

    def group_of(self, m: Machine | str) -> str:
        """The group of a server, a canary or a device (by name)."""
        if isinstance(m, str):
            return next(g.name for g in self.group if m in g.devices)
        if isinstance(m, Canary):
            target = self.find(m.watches)
            if isinstance(target, Server):
                return self.group_of(target)
            # A group with no server would carry it nowhere, and burn the relay.
            served = self.groups_of(target)
            return next((g for g in served if self.servers_of(g)), served[0])
        return m.group or self.group[0].name

    def groups_of(self, r: Relay) -> list[str]:
        return r.groups if r.groups is not None else [g.name for g in self.group]

    def servers_of(self, group: str) -> list[Server]:
        return [s for s in self.server if self.group_of(s) == group]

    def clients_of(self, group: str) -> list[str]:
        """Who a group's servers let in by vless_clients: its devices and its
        canaries, each through its own id. Relays come in by ids the servers
        derive (relay_seed), and go in no one's vless_clients."""
        devices = next(g.devices for g in self.group if g.name == group)
        return [*devices, *(f"canary-{c.name}" for c in self.canary if self.group_of(c) == group)]

    @model_validator(mode="before")
    @classmethod
    def _moved(cls, data: Any) -> Any:
        if isinstance(data, dict) and "devices" in data:
            raise ValueError("devices: a device belongs to a server group now: list them under [[group]], "
                             'name = "<the servers\' name>", devices = [...]')
        return data

    @model_validator(mode="after")
    def _references(self) -> "Network":
        names: set[str] = set()
        ids: dict[str, str] = {}
        for m in self.machines:
            if m.name in names:
                raise ValueError(f"[[{m.kind}]] name {m.name!r} is taken")
            names.add(m.name)
            # Two machines on one installation would republish each other's
            # document on every sync.
            if m.id and m.id in ids:
                raise ValueError(f"{m.name} has the installation id of {ids[m.id]}")
            if m.id:
                ids[m.id] = m.name
        groups = [g.name for g in self.group]
        if len(set(groups)) < len(groups):
            raise ValueError("two [[group]]s have one name")
        # A device's id is its own, so it is in one group: one in two would be
        # dropped from both by every relay serving them.
        for d in self.devices:
            if d in names or d.startswith(("relay-", "canary-")):
                raise ValueError(f"device {d!r} is not a free name, or in two groups (relay- and canary- are the manager's)")
            names.add(d)
        for s in self.server:
            if s.group is None and len(groups) != 1:
                raise ValueError(f"server {s.name} names no group, and the roster has {len(groups)}: give it group = ...")
            if s.group is not None and s.group not in groups:
                raise ValueError(f"server {s.name} is in group {s.group!r}, which no [[group]] names")
        relays = {r.name: r for r in self.relay}
        for r in self.relay:
            if not self.groups_of(r) or any(g not in groups for g in self.groups_of(r)):
                raise ValueError(f"relay {r.name} serves {self.groups_of(r)}: name one [[group]] at least, and only those")
            if r.tunnel_group is not None and r.tunnel_group not in self.groups_of(r):
                raise ValueError(f"relay {r.name} has tunnel_group {r.tunnel_group!r}, a group it doesn't serve")
            for v in r.via:
                if v not in relays or v == r.name:
                    raise ValueError(f"relay {r.name} goes via {v!r}, which is no other relay here")
                # The relay it goes through lets it in by its id on each
                # group, which only a group that relay serves gives it.
                if lacking := [g for g in self.groups_of(r) if g not in self.groups_of(relays[v])]:
                    raise ValueError(f"relay {r.name} goes via {v}, which doesn't serve {', '.join(lacking)}")
            # Following via from here must end at relays that go to the servers.
            seen, todo = {r.name}, list(r.via)
            while todo:
                v = todo.pop()
                if v == r.name:
                    raise ValueError(f"relay {r.name} goes via a loop back to itself")
                if v not in seen:
                    seen.add(v)
                    todo.extend(relays[v].via)
        targets = {m.name for m in [*self.server, *self.relay]}
        for c in self.canary:
            if c.watches not in targets:
                raise ValueError(f"canary {c.name} watches {c.watches!r}, which is no server or relay here")
        for d in self.desktops:
            if d not in self.devices:
                raise ValueError(f"desktop {d!r} is not in a group's devices")
        for c in self.client:
            if c.device not in self.devices:
                raise ValueError(f"client {c.name} follows device {c.device!r}, which no group's devices list")
            if not self.subscription:
                raise ValueError("client machines follow a subscription: set subscription = true")
        return self


def with_joined(net: Network, joined: dict[str, dict[str, str]]) -> Network:
    """The roster with the id and key `joined` kept (the state's joined) for
    each machine whose roster entry gives neither: the roster's own win."""
    def fill(ms: list) -> list:
        return [m.model_copy(update=joined[m.name]) if m.name in joined and m.id is None and m.key is None else m
                for m in ms]

    return net.model_copy(update={kind: fill(getattr(net, kind)) for kind in KINDS})


def loads(text: str, origin: str = "network.toml") -> Network:
    try:
        return Network.model_validate(tomllib.loads(text))
    except tomllib.TOMLDecodeError as e:
        raise Refused(f"{origin}: {e}") from None
    except ValidationError as e:
        raise Refused(f"{origin}: " + "; ".join(_say(err) for err in e.errors())) from None


def load(path: Path) -> Network:
    if not path.is_file():
        raise Refused(f"{path}: no roster here; --roster names another")
    return loads(path.read_text(), str(path))


def _say(err) -> str:
    where = ".".join(str(part) for part in err["loc"])
    what = str(err["ctx"]["error"]) if "error" in err.get("ctx", {}) else err["msg"]
    return f"{where}: {what}" if where else what
