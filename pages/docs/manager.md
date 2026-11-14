# Manager

`dotdash-manager` runs a whole network from one roster: servers, relays,
canaries, client machines and devices. It makes the keys the servers share,
gives every server and relay the same devices, writes the servers' `relays`
and the relays' way to the servers from what each machine reports, and keeps
canaries and clients pointed at them.

It never logs in to a machine. Each machine follows it through morzer's
[desired state](https://morzecrew.github.io/morzer/latest/operating/managing-from-elsewhere/):
it pulls a signed, encrypted document from a bucket every 15 minutes and
publishes its [facts](server/operations.md#managed-from-elsewhere) there. The
manager runs where you keep the authority key, never on a managed machine.

```text
network.toml ──▶ dotdash-manager sync ──▶ one document per machine ──▶ the bucket ──▶ each machine
                         ▲                                                  │
                         └──────────── servers' and relays' facts ◀─────────┘
```

It needs morzer and age-keygen beside it, and installs with
[uv](https://docs.astral.sh/uv/) at the tag of the release your machines run,
such as `v0.7.0`:

```sh
uv tool install "git+https://github.com/morzecrew/dotdash@<tag>#subdirectory=manager"
```

To move to a later release, run it again with that tag and `--force`.

## Set it up

```sh
morzer state key generate ./authority.key   # prints the public key: authority below
age-keygen -o ./authority.age               # facts are encrypted to it
```

Keep both off the machines. Whoever holds `authority.key` sets everything the
bundles let it, devices and keys included.

Then the roster, `network.toml`:

```toml
target = "s3://dotdash-state/net"           # a bucket every machine reaches
credentials = "./target-credential.yaml"    # morzer's credential document for it
key = "./authority.key"
identity = "./authority.age"
authority = "RWQ…"                          # what state key generate printed
subscription = true                         # every device gets a subscription URL
ipv6 = "allow"                              # or block, on the relays
direct = false                              # optional: devices reach servers only through relays and CDNs
devices = ["phone", "laptop"]

[pools]                                     # optional: the server's pools, member by member
a = ["laptop", "203.0.113.5"]

[[server]]
name = "a"
cdn_hosts = ["cdn.example.net"]             # optional: this server's cdn_hosts

[[relay]]
name = "r1"

[[canary]]
name = "c1"
watches = "r1"                              # a server or a relay

[[client]]
name = "home"
device = "phone"                            # the device whose subscription it follows
```

With `direct = false` the servers keep their addresses out of devices'
links ([direct](server/devices.md#keeping-the-servers-out-of-devices-links)),
and client machines fetch their subscription through an own-site relay,
waiting for one. Left out, each server keeps its own setting.

Names are lowercase letters, digits and dashes. `relay-` and `canary-` start
the names the manager gives relays' and canaries' own devices. A field the
roster doesn't know is refused, so a mistyped one can't pass unnoticed.

## Add a machine

Name it in the roster first. Then:

```sh
dotdash-manager sync          # the servers learn its device
dotdash-manager join r1       # what to run on it
```

`join` prints the machine's `init`, its secrets and its sync settings, as
`relay-config` does, and the line that reads its installation id and signing
key. Give it those in the roster:

```toml
[[relay]]
name = "r1"
id = "inst_01…"
key = "RW…"
```

Then run `sync` again. A new server comes up on keys of its own: the first
document replaces them, and relays, canaries and clients move to it once its
facts show the manager's key. A relay, canary or client waits for a server
that has.

## Keep it current

```sh
dotdash-manager sync --dry-run   # what would change
dotdash-manager sync
dotdash-manager status           # what each machine applied and refused
```

`sync` publishes only documents that changed, and renews the rest every three
days: a document expires after seven. Run it from a timer to keep it ahead of
that. A device added to `devices` reaches every server and relay at the next
sync; one removed loses its access everywhere, each machine within its next
cycle.

The manager keeps what it made in `dotdash-state.json` beside the roster: the
shared keys, every device's id and the client machines' proxy passwords. It is
written with mode 0600 and holds every credential in the network: back it up
like `authority.key`.

## What it leaves alone

The upstreams, ports, profiles, domains and anything else a machine alone
knows stay the operator's, set on that machine as before. A value the manager
sets is refused by `config set` on the machine while sync is on; `--force`
changes it until the next document.
