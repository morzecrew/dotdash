"""The roster, network.toml: the servers, relays, canaries, client machines and devices."""

import re
import tomllib
from pathlib import Path
from typing import Annotated, ClassVar, Literal

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


class Server(Machine):
    kind: ClassVar[str] = "server"
    cdn_hosts: list[str] = []


class Relay(Machine):
    kind: ClassVar[str] = "relay"


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

    def clients_of(self, kind: str) -> list[str]:
        """Who a server's or a relay's vless_clients lets in: every device and canary,
        and on a server every relay, each through its own id."""
        names = [*self.devices, *(f"canary-{c.name}" for c in self.canary)]
        return names + ([f"relay-{r.name}" for r in self.relay] if kind == "server" else [])

    @model_validator(mode="after")
    def _references(self) -> "Network":
        names: set[str] = set()
        for m in self.machines:
            if m.name in names:
                raise ValueError(f"[[{m.kind}]] name {m.name!r} is taken")
            names.add(m.name)
        for d in self.devices:
            if d in names or d.startswith(("relay-", "canary-")):
                raise ValueError(f"device {d!r} is not a free name (relay- and canary- are the manager's)")
            names.add(d)
        targets = {m.name for m in [*self.server, *self.relay]}
        for c in self.canary:
            if c.watches not in targets:
                raise ValueError(f"canary {c.name} watches {c.watches!r}, which is no server or relay here")
        for c in self.client:
            if c.device not in self.devices:
                raise ValueError(f"client {c.name} follows device {c.device!r}, which devices does not list")
            if not self.subscription:
                raise ValueError("client machines follow a subscription: set subscription = true")
        return self


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
