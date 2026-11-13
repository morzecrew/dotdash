"""What the manager made and keeps beside the roster, dotdash-state.json: the
shared keys, every device's id, the client machines' proxy passwords and what
went out. Every credential in the network is in it, so it is written 0600."""

import base64
import json
import os
import secrets
import uuid
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from .roster import Network

# Each secret the servers share, as its generator in bundles/server/secrets.schema.yaml makes it.
SHARED_KEYS = {
    "reality_key": lambda: b64url(secrets.token_bytes(32)),
    "vless_seed": lambda: secrets.token_hex(64),
    "reality_short_id": lambda: secrets.token_hex(8),
    "xhttp_path": lambda: secrets.token_hex(16),
    "kcp_seed": lambda: secrets.token_hex(16),
    "subscription_key": lambda: secrets.token_hex(32),
}


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def public_key(reality_key: str) -> str:
    """A REALITY key's public half, which tells a server that applied the
    manager's keys from one that has not."""
    private = base64.urlsafe_b64decode(reality_key + "=" * (-len(reality_key) % 4))
    return b64url(X25519PrivateKey.from_private_bytes(private).public_key().public_bytes_raw())


def load(path: Path, net: Network) -> dict:
    """The state, with whatever the roster now needs and it lacks made."""
    state = json.loads(path.read_text()) if path.exists() else {}
    keys = state.setdefault("keys", {})
    for name, make in SHARED_KEYS.items():
        keys.setdefault(name, make())
    ids = state.setdefault("ids", {})
    for name in net.clients_of("server"):
        ids.setdefault(name, str(uuid.uuid4()))
    passwords = state.setdefault("passwords", {})
    for c in net.client:
        passwords.setdefault(c.name, secrets.token_urlsafe(18))
    state.setdefault("published", {})
    return state


def save(path: Path, state: dict) -> None:
    tmp = path.with_suffix(".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)
    os.replace(tmp, path)
