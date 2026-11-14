"""dotdash-manager: a dotdash network from one roster, through morzer's desired state.

The roster (network.toml) names the servers, relays, canaries, clients and
devices. The manager makes the keys the servers share, reads the facts the
servers and relays publish (`morzer state facts`), renders every machine's
document and publishes the ones that changed (`morzer state publish`). It never
reaches a machine: each pulls its own document. Docs: pages/docs/manager.md.
"""


class Refused(Exception):
    """Something the operator has to fix first; the message says what."""
