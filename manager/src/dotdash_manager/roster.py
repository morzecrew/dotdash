"""The roster, network.toml: the servers, relays, canaries, client machines and devices."""

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


class Server(Target):
    kind: ClassVar[str] = "server"
    cdn_hosts: list[str] = []


class Relay(Target):
    kind: ClassVar[str] = "relay"
    # A spare: installed, given its document and watched by its canaries like
    # any relay, but kept out of what devices get until a burnt relay's place
    # needs it (health.spares).
    spare: bool = False
    # Standby: in what devices get, but last, unchecked, and used only once
    # every other link fails (its line in the servers' relays ends standby).
    standby: bool = False
    # Other relays this one goes through instead of the servers (its via):
    # they let it in by its own id, and the servers never see its address.
    via: list[Name] = []
    # How it reaches them: REALITY, or XHTTP through their own sites.
    via_link: Literal["reality", "xhttp"] = "reality"
    # The TLS client hello the xhttp via leg shows: a browser, or none for
    # Xray's own Go TLS stack (server-shaped). Only affects via_link="xhttp".
    via_fingerprint: Literal[
        "chrome", "firefox", "safari", "edge", "ios", "android", "random", "none"
    ] = "chrome"


class Canary(Machine):
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
    devices: list[Name] = []
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

    def find(self, name: str) -> Machine | None:
        return next((m for m in self.machines if m.name == name), None)

    def clients_of(self, kind: str, relay: str | None = None) -> list[str]:
        """Who a server's or a relay's vless_clients lets in: every device and canary,
        on a server every relay, and on the relay named those that go via it,
        each through its own id."""
        names = [*self.devices, *(f"canary-{c.name}" for c in self.canary)]
        return names + [f"relay-{r.name}" for r in self.relay if kind == "server" or relay in r.via]

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
        for d in self.devices:
            if d in names or d.startswith(("relay-", "canary-")):
                raise ValueError(f"device {d!r} is not a free name (relay- and canary- are the manager's)")
            names.add(d)
        relays = {r.name: r for r in self.relay}
        for r in self.relay:
            for v in r.via:
                if v not in relays or v == r.name:
                    raise ValueError(f"relay {r.name} goes via {v!r}, which is no other relay here")
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
                raise ValueError(f"desktop {d!r} is not in devices")
        for c in self.client:
            if c.device not in self.devices:
                raise ValueError(f"client {c.name} follows device {c.device!r}, which devices does not list")
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
