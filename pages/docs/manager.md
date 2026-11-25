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
desktops = ["laptop"]                       # optional: devices that get no CDN link (desktops in Devices)

[pools]                                     # optional: the server's pools, member by member
a = ["laptop", "203.0.113.5"]

[[server]]
name = "a"
cdn_hosts = ["cdn.example.net"]             # optional: this server's cdn_hosts

[[relay]]
name = "r1"
provider = "hoster-a"                       # optional: your own name for who hosts it
address_since = 2026-11-01                  # optional: since when it has this address
standby = true                              # optional: devices use it only once every other link fails
via = ["r0"]                                # optional: relays it goes through instead of the servers
via_link = "xhttp"                          # optional, with via: reality (the default) or xhttp through their own sites

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

A relay with `via` goes through those relays instead of the servers
([Through another relay](relay/operations.md#through-another-relay)): they
let it in by its own id, and its document waits for their facts. A relay
running a release from before `via` waits to be updated rather than going to
the servers.

Names are lowercase letters, digits and dashes. `relay-` and `canary-` start
the names the manager gives relays' and canaries' own devices. A field the
roster doesn't know is refused, so a mistyped one can't pass unnoticed.

## Add a machine

Name it in the roster first, run `sync` so the servers learn its device, then
pipe `join`'s script to the new machine over ssh, and what it prints back to
`joined`:

```sh
dotdash-manager sync
dotdash-manager join r1 --site site.example.net --entry-host 203.0.113.7 \
  | ssh root@203.0.113.7 sh | dotdash-manager joined r1
dotdash-manager sync          # r1 gets its document
```

The script installs what the machine lacks (`scripts/bootstrap.sh`, as on a
fresh Debian or Ubuntu), runs its `init` with the values it needs, sets its
secrets, points it at the manager and applies. On a machine where the bundle
is installed already, it leaves the installation as it is and only points it
at the manager, whose document brings the rest. Its last line carries the
machine's installation id and signing key, which `joined` keeps in the
manager's state, so the next `sync` sends the machine its document. The rest
of its output passes through, so a failure shows; `joined` then keeps
nothing, and the script can run again.

What each kind needs to be installed:

- **A server:** `--domain` and `--upstreams <file>`, its ways out, one per
  line. It comes up on keys of its own: the first document replaces them, and
  relays, canaries and clients move to it once its facts show the manager's
  key. A relay, canary or client waits for a server that has.
- **A relay:** `--site` and `--entry-host` (a neighbour's site, and the
  address devices reach it at), or `--domain` for one of its own site.
- **A canary or a client:** nothing more.

Backups go to the manager's target, encrypted to the identity's age
recipient or to `--recovery`. A machine installed before it joined gets both
too, so its backups outlive it.
The script holds the machine's credentials: send it to that machine only. A
roster entry's own `id` and `key`, as earlier releases had you write them,
still win over what `joined` kept.

## Moving a running network

A network set up by hand moves to the manager without devices noticing: the
manager takes a running server's keys and its devices' ids instead of making
its own, so devices keep their links and subscription URLs. Name the server,
its relays and the devices in the roster under the names the server already
uses (`client-config` prints them), then, before the first `sync`:

```sh
dotdash-manager adopt a       # prints what to run on server a
ssh root@a.example 'sudo sh -c …' | dotdash-manager adopt a
```

It says which devices keep their links, which are new to the server, and
which the server has but the roster doesn't, which lose access at the next
`sync` unless you add them. Finish a [key rotation](#rotating-the-reality-key)
first: only the current key is taken. Once the manager has published, `adopt`
refuses, since it would change the keys on every machine again; `--force` when
that is meant.

Then join every machine as above, the running server and relays included,
with no options: the script finds them installed and only points them at the
manager. Relays keep their own keys, so devices keep their relay links too.

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
like `authority.key`. One run at a time changes it: a run holds
`dotdash-state.lock` beside it, and another started meanwhile, such as a timer's
`sync` during a `rotate`, waits for it. `sync --dry-run` leaves it as it was.

## Burnt relays

Before every fleet publish, about hourly, each canary that follows the manager
reports whether each of its paths to the server or relay it watches gets
through. When every canary watching a relay got through none of its paths
three readings in a row, `sync` leaves that relay out of the servers' `relays`
and `pools`, and of client machines' subscription URLs, and says so. A
reading counts only beside the newest of the other canaries watching the same
relay within 90 minutes, so a canary gone quiet can't hold the relay up with an
old success:

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

## Leaked links

With the `device-traffic` profile on the servers and relays
([server](server/operations.md#device-traffic),
[relay](relay/reference.md)), their facts carry how many bytes each device
has moved. `sync` adds each device's bytes up by day, over the last 30 days.
It names a device whose day reached five times its median day and at least
2 GB, once it has 7 days to judge by:

```
phone-2: 14.2 GB on 2026-12-03, against 0.4 GB on its usual day: if its link may have leaked, delete the device and add it again
```

`sync` prints yesterday's and today's; `report` ends with the last 30 days'.
A link passed around shows this way: its device suddenly moves far more than
it ever did. A long video call or a big download can too, so ask before
deleting the device. Only counts reach the manager, never an address. They
are an hour behind at most, as the facts refresh hourly. A server or relay
that restarts loses only what it counted since the last refresh.

## Rotating the REALITY key

`rotate` changes the servers' REALITY key with no device cut off, over their
second key ([Rotating the REALITY key](server/secrets.md#rotating-the-reality-key)),
in three steps, each published by the next `sync`:

```sh
dotdash-manager rotate start     # the next key second on the servers; their canaries move to it
dotdash-manager sync
dotdash-manager rotate swap      # once a canary got through on it: the key now, the old one second
dotdash-manager sync
dotdash-manager rotate finish    # a week later: the old key off
dotdash-manager sync
```

- **`start`** gives the servers a next key as their second. Only the canaries
  watching servers move to it: devices and relays keep the current key.
- **`swap`** refuses until one of those canaries has got REALITY through on
  the next key since `start`. It then makes the next key the servers' key and
  keeps the old one second. Subscriptions, client machines and relays move to
  the new key, and devices still on the old one keep getting in.
- **`finish`** refuses for a week after `swap`, the devices' time to fetch
  their subscriptions or get new links. It then turns the old key off.
- `rotate` alone says where it stands. `--force` skips the canary check or
  the week, when you know better.

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

## A name blocked by SNI

A box can block a server's name by the SNI in each ClientHello, reassembling
TCP but reading one TLS record at a time. Its canaries see REALITY fail while
[REALITY with its hello split](canary/index.md#what-it-checks) into small TLS
records gets through. After three readings like that in a row, `sync` sets the
server's `hello_split`:

```
split: server a: REALITY gets through only with its hello split into TLS records, a block on its name by SNI; devices' Xray configs split it (hello_split), share links can't
```

- **Who it reaches.** Devices running Xray from their subscription's config,
  such as `dotdash-client` or an app on `client-config --full`, split their
  REALITY hello to that server from their next refresh. Share links can't
  carry it, so apps on links keep failing there and use another path.
- **Off again.** It goes off once REALITY gets through again, or once the
  split fails too.
- **Why not always on.** The split hello is a fingerprint of its own, which a
  classifier picks up (dotdash-lab #33).
- **Relays too.** A relay's canaries can find the same of its site's name.
  Its line then gets `split` beside `off=reality`. Share links lose REALITY
  through it, as for any blocked path, while devices' Xray configs keep it,
  split. A burnt relay stays out.

## What it leaves alone

The upstreams, ports, profiles, domains and anything else a machine alone
knows stay the operator's, set on that machine as before. A value the manager
sets is refused by `config set` on the machine while sync is on; `--force`
changes it until the next document.
