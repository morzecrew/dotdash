"""What the manager made and keeps beside the roster, dotdash-state.json: the
shared keys, every device's id, the client machines' proxy passwords and what
went out. Every credential in the network is in it, so it is written 0600."""

import base64
import fcntl
import json
import os
import secrets
import sys
import tempfile
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
    """The state, with whatever the roster now needs and it lacks made, and
    the ids and passwords of whoever left it dropped: one taken out and added
    again gets a new id (so new links and subscription URL) or password, and
    what leaked of the old ones lets no one in."""
    state = json.loads(path.read_text()) if path.exists() else {}
    keys = state.setdefault("keys", {})
    for name, make in SHARED_KEYS.items():
        keys.setdefault(name, make())
    names = net.clients_of("server")
    ids = state["ids"] = {n: i for n, i in state.get("ids", {}).items() if n in names}
    for name in names:
        ids.setdefault(name, str(uuid.uuid4()))
    clients = {c.name for c in net.client}
    passwords = state["passwords"] = {n: p for n, p in state.get("passwords", {}).items() if n in clients}
    for name in clients:
        passwords.setdefault(name, secrets.token_urlsafe(18))
    state.setdefault("published", {})
    return state


def lock(path: Path) -> int:
    """Hold <state>.lock beside the state until the process exits: one run at
    a time reads, changes and writes the state, so a timer's sync and a rotate
    typed meanwhile can't lose each other's changes."""
    fd = os.open(path.with_name(f"{path.stem}.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print(f"waiting for another dotdash-manager run on {path}", file=sys.stderr)
        fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def save(path: Path, state: dict) -> None:
    """Written whole to a file of its own beside it (0600, as mkstemp makes
    it), synced, then moved over it: a crash leaves the old state or the new."""
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(state, f, indent=1, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise
    d = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(d)
    finally:
        os.close(d)
