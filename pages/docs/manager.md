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
provider = "hoster-a"                       # optional: your own name for who hosts it
address_since = 2026-11-01                  # optional: since when it has this address

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

## Burnt relays

Before every fleet publish, about hourly, each canary that follows the manager
reports whether each of its paths to the server or relay it watches gets
through. When every canary watching a relay got through none of its paths
three readings in a row, `sync` leaves that relay out of the servers' `relays`
and `pools`, and of client machines' subscription URLs, and says so:

```
burnt: relay r1: its canaries got through none of its paths in 3 readings; left out of the servers' relays and pools until a canary gets through again; its own fleet row (40m old) says it runs: blocked on the way, not down; replace it
```

Devices stop getting its links at their next subscription refresh. The relay
keeps its own document and its canaries keep watching it, so a single reading
that gets through brings it back. To replace it, [add](#add-a-machine) a relay
on a fresh address, then take the burnt one out of the roster.

The verdict also says what the relay's own fleet row, which it publishes
hourly, says of it. A relay whose row is fresh and whose services all run is
blocked on the way, and replacing its address is the fix. One whose row has
gone quiet for three hours, or whose services aren't all running, is likelier
down than blocked: the verdict says to fix it first, and doesn't say to
replace it. A row that doesn't verify says nothing either way.

- **A canary whose own network is down says nothing**, given a `control_url`:
  a site its network reaches without dotdash. A reading where that fails
  doesn't count. Without one, an offline canary looks like a burnt relay.
- **Every relay at once is kept.** If every relay would be left out in the
  same sync, the manager keeps them all and says to check the canaries'
  network instead.
- **A burnt server is only reported.** Relays reach the servers, so leaving
  one out would cut them off.
- **A relay no canary watches is never judged.** Run canaries where devices
  are: [on a mobile line](canary/index.md#on-a-mobile-line).
- **Neither is a [CDN-only relay](server/cdn.md#the-cdns-origin-only).** Its
  canaries check its own address, which no device gets.

## Spare relays

A burnt relay waits for you to replace it. A spare takes its place at the
next sync instead, about an hour after the third failed reading. Install a
relay as usual, [add](#add-a-machine) it to the roster with `spare = true`,
and point a canary at it:

```toml
[[relay]]
name = "r3"
spare = true

[[canary]]
name = "c3"
watches = "r3"
```

A spare gets its document and runs like any relay, and its canary watches it,
but devices don't get it: it's out of the servers' `relays` and `pools`. When
a relay burns, the first spare that isn't burnt itself stands in for it, and
takes its place in the pools. Spares a canary has got through to go first,
in roster order; one no canary has checked yet still stands in, and `sync`
says to check it:

```
spare: r3 stands in for burnt relay r1, in its pools; replace r1, then make r3 a regular relay (spare = false) and add a new spare
```

A spare stands in only while the relay it replaces is burnt. If a canary
gets through to that relay again, it's back and the spare waits again. Each
burnt relay takes one spare, in roster order; with none left, `sync` says so.

A spare burnt while it waits was blocked without any device holding its
address: for its network's range, say, or found by scanning. That's worth
knowing when you pick where the next one goes.

## How long relays last

Every `sync` logs what changed: a server or relay its canaries start
watching, one that burns or comes back, one that leaves the roster, a path
going off or on, a spare standing in or waiting again. `report` reads that
log:

```sh
dotdash-manager report
```

```
machine      kind    status   watched          lasted burns     down  paths off
s            server  up       2026-11-01      14d 3h+     0        -  -
r1           relay   burnt    2026-11-01       10d 0h     2    4d 2h  reality×1
r2           relay   up       2026-11-03      12d 1h+     0        -  -
r3           spare   standing 2026-11-05            -     0        -  -; stood in 1×
old          gone    gone     2026-10-20        4d 0h     1    1d 0h  -

relays: 2 burnt, lasting 7d 0h at the median
        1 never burnt, watched 12d 1h so far
        1 burn(s) in the last 30 days; spares waiting: none
```

`lasted` runs from the first reading to the first burn, or until now with
a `+` for one that hasn't burnt yet; `down` adds up the time it spent
burnt. A relay taken out of the roster stays in the report, as `gone`: how
long the ones you replaced lasted is what tells whether a change (a
transport, a network, a provider) makes the next ones last longer. The log
keeps the newest 2000 events, and starts with the first `sync` of a manager
that has it.

Then how long each path lasted before it was first blocked, a burn
included, and the median per path: which transport lasts.

```
paths: how long each lasted before it was first blocked (+: never yet)
machine             reality          xhttp  xhttp-reality           mkcp      hysteria2
r1                   10d 0h          4d 2h              -              -        16d 0h+
r2                  16d 0h+        16d 0h+              -              -        16d 0h+
old                   4d 0h              -              -              -              -
median to first block: reality 7d 0h (2 blocked, 1 never); xhttp 4d 2h (1 blocked, 1 never); hysteria2 never blocked (2, 16d 0h longest)
```

With `provider`, and `address_since` if you know it, on servers and relays
in the roster, the lifetimes also add up per provider, and with how old the
addresses were when their canaries first watched them. Both are your own
record: nothing is looked up, and `sync` keeps them for machines you take out
of the roster.

```
by provider (the roster's provider), servers and relays: burnt and their median life, never burnt
hoster-a         2 burnt, 7d 0h at the median; addresses 3d 0h old when first watched, at the median
hoster-b         0 burnt; 1 never burnt (16d 0h so far)
```

## Where the time goes

Each canary's `facts` time its paths and its own network
([`latency_ms` and `direct_ms`](canary/index.md)), and `sync` keeps each
machine's last 24 readings. The report ends with their medians:

```
latency, ms (median of the last readings): the canaries' own network, then each path through it
s            network    90   reality 210, xhttp 180
r1           network   100   reality 290 (+80 over the servers)
```

A path's time less `network` is what dotdash adds: the target, its upstream
and the site. For a relay, the figure in brackets is what it adds over the
servers on the same path, which is the hop to the server. That's close
enough to compare relays, but canaries sit on different networks, so it is
no exact measure. A machine whose canaries predate these timings is left out
until they update.

## Blocked paths

Short of burnt, a relay can lose one path while its others get through: its
REALITY port cut while XHTTP through its own site still answers, mKCP
dropped, or one path's connections frozen after their first few kilobytes,
which a canary's [freeze download](canary/index.md#what-it-checks) catches. When every canary watching a relay got through none of its readings
on one path three times in a row, and another path got through, `sync` puts
that path on the relay's line as `off=`:

```
blocked: relay r1: reality got through for none of its canaries in 3 readings; devices get its other paths until one gets through again
```

Devices then get only its other links through it (and its CDN links, which
canaries don't check), at their next subscription refresh. A reading where the
path gets through again takes it off.

- **A path blocked on every relay that has it is kept.** That's likelier the
  canaries' network refusing the transport than every relay losing it at
  once, so the manager says to check that network instead.
- **A server's blocked paths are only reported**, as a burnt server is.
- **A server released before `off=` ignores the field** and gives devices
  every link through the relay, as before.

## What it leaves alone

The upstreams, ports, profiles, domains and anything else a machine alone
knows stay the operator's, set on that machine as before. A value the manager
sets is refused by `config set` on the machine while sync is on; `--force`
changes it until the next document.
