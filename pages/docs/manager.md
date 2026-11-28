# Manager

`dotdash-manager` runs a whole network from one roster: server groups and
their devices, servers, relays, canaries and client machines. It makes each
group's keys, gives each group's servers its devices, writes the servers'
`relays` and each relay's `servers` from what each machine reports, and keeps
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
such as `v0.7.0`. A manager with server groups runs servers and relays of
0.19 or later ([Moving to server groups](#moving-to-server-groups)):

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
desktops = ["laptop"]                       # optional: devices that get no CDN link (desktops in Devices)
# optional: every server's cdn_extra, by CDN name (A CDN that fetches in plain HTTP)
cdn_extra = { "edge.example.net" = { uplinkHTTPMethod = "GET", xPaddingObfsMode = true } }
# optional: the servers' pools, member by member
pools = { p = ["laptop", "203.0.113.5"] }

[[group]]                                   # servers sharing keys, and their devices
name = "a"                                  # its servers' name: opaque, as apps show it
devices = ["phone", "laptop"]

[[group]]
name = "b"
devices = ["tablet"]

[[server]]
name = "a1"
group = "a"                                 # optional with one [[group]]
cdn_hosts = ["cdn.example.net"]             # optional: this server's cdn_hosts

[[server]]
name = "b1"
group = "b"

[[relay]]
name = "r1"                                 # its own name parameter too, at join
groups = ["a"]                              # optional: the groups it carries; every group by default
server_link = "xhttp-reality"               # optional: reality (the default), or XHTTP with REALITY where servers have it
tunnel_group = "a"                          # optional: the group a cover app's tunnel_host goes through; its first by default
provider = "hoster-a"                       # optional: your own name for who hosts it
address_since = 2026-11-01                  # optional: since when it has this address
standby = true                              # optional: devices use it only once every other link fails
via = ["r0"]                                # optional: relays it goes through instead of the servers
via_link = "xhttp"                          # optional, with via: reality (the default) or xhttp through their own sites
credentials = "./r1-credential.yaml"        # optional, on any machine: its own credential document (Bucket credentials)

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
waiting for one: the first that their device's `pools` give it, as the
servers choose a device's relays. Left out, each server keeps its own
setting.

A relay with `via` goes through those relays instead of the servers
([Through another relay](relay/operations.md#through-another-relay)): they
let it in by its id on each group, so each of them serves every group it
does. Its document waits for their facts.

Names are lowercase letters, digits and dashes; a relay's at most 24, as its
own `name` takes them, and a group's 1 to 16 letters and digits, starting
with a letter. `relay-` and `canary-` start the names the manager gives
relays' and canaries' own devices. A field the roster doesn't know is
refused, so a mistyped one can't pass unnoticed. In TOML, every top-level key
comes before the first `[[group]]`.

## Server groups

A group is servers that share keys, as [several servers](server/several-servers.md)
do, and the devices they let in. Each group has its own keys, `relay_seed`
and exit, and its devices reach no other group's servers. A network of one
group, as before, is one `[[group]]`, and its servers need no `group`.

- **Each group's servers** get its keys, its devices and its name, which
  relays know the group by and the servers' own links are named by
  (`a · reality`). A device is in one group: a phone that uses two is two
  devices, with a subscription each.
- **Every relay serves every group**, unless `groups` narrows it: one relay
  carries each device to its own group's servers and exit alone
  ([One relay, several server groups](relay/gateway.md)). The servers of
  each group it serves get its `relay/1` line in `relays`, from its facts.
  The relay gets a `server/1` line in its `servers` per group, made of that
  group's servers that applied its keys and the relay's id there, which the
  manager derives from the group's `relay_seed` and the relay's name and
  nonce, as the servers do. Nobody adds a relay to `vless_clients`, and no
  document carries a relay devices: it fetches each group's list from its
  servers every minute, so a device added reaches it with no new document.
- **A canary** is a device of one group: the group of the server it
  watches, or for a relay the first group it serves that has a server.
- **A group's keys** are kept in the state by its name. Renaming a group
  gives its servers new keys, which cuts its devices off, as a new group:
  name it back, and its old keys are still there.

A relay whose group's servers are changing keys (a rotation's swap, or a
server that joined on keys of its own) keeps its last document until they
applied them, rather than drop that group's devices. A group that has no
server with facts yet is left out of its `servers` until one has.

## Add a machine

Name it in the roster first, then pipe `join`'s script to the new machine
over ssh, and what it prints back to `joined`. A canary needs a `sync` first,
so its group's servers learn its device:

```sh
dotdash-manager join r1 --site site.example.net --entry-host 203.0.113.7 \
  | ssh root@203.0.113.7 sh | dotdash-manager joined r1
dotdash-manager sync          # r1's line to the servers, theirs to r1
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
  key. A relay's line for its group waits for a server of the group that
  has, and so do the group's canaries and clients.
- **A relay:** `--site` and `--entry-host` (a neighbour's site, and the
  address devices reach it at), or `--domain` for one of its own site. It
  comes up idle under its roster name, with a nonce it makes, which its facts
  carry. The next `sync` puts its `relay/1` line in the servers' `relays`
  and their `server/1` lines in its `servers`; within a minute of applying
  both it has each group's devices.
- **A canary or a client:** nothing more.

Backups go to the manager's target under `backups/<name>/`, a prefix of the
machine's own, encrypted to the identity's age recipient or to `--recovery`.
A machine installed before it joined gets both too, so its backups outlive
it.
The script holds the machine's credentials: send it to that machine only. A
roster entry's own `id` and `key`, as earlier releases had you write them,
still win over what `joined` kept.

## Bucket credentials

`join` hands each machine the network's `credentials`, the same document the
manager uses, unless the machine's roster entry names one of its own. With
one credential for all, a seized relay can delete or overwrite every
server's documents, fleet rows, facts and backups. Signatures keep it from
forging them, not from destroying them. A credential per machine, scoped to
its own prefixes on the target, bounds that:

| Whose | List | Read | Write | Delete |
| --- | --- | --- | --- | --- |
| the manager's (`credentials` at the top) | the target | `fleet/`, `state/` | `state/` | `state/`, to prune old documents |
| a machine's (its `credentials`) | the target | `state/<product>/<installation-id>/`, `backups/<name>/` | `fleet/<product>/<installation-id>/` (its row and facts), `backups/<name>/` | `backups/<name>/`, for retention |

The product is `dotdash`, `dotdash-relay`, `dotdash-canary` or
`dotdash-client`; the installation id is the one `joined` kept, which
`morzer installation describe` on the machine prints. The name is the
machine's in the roster.

morzer prunes every backup it finds one level under a target's root, so
machines that keep backups at one root prune each other's, and two that back
up in the same second overwrite each other's. Each joined machine therefore
backs up under `backups/<name>/`. A machine joined before kept its backups
at the root: run its `join` again, and the script moves it to its prefix and
drops the root target. The backups already at the root stay there; nothing
prunes them now, so delete them once each machine has a backup under its
prefix. Versioning or Object Lock, where the bucket has them, still guards
against a seized machine deleting its own.

To move a joined machine to its own credential, name it in the roster and
run its `join` again: the script replaces the credential it holds.

## Moving a running network

A network set up by hand moves to the manager without devices noticing: the
manager takes a running server's keys and its devices' ids instead of making
its own, so devices keep their links and subscription URLs. Move the servers
and relays to 0.19 first, by hand ([Moving from 0.18](relay/gateway.md#moving-from-018)).
Name each group, its servers, the relays and the devices in the roster under
the names the servers already use (`client-config` prints them; a group is
named by its servers' `name`), then, before the first `sync`, adopt one
server of each group:

```sh
dotdash-manager adopt a1      # prints what to run on server a1
ssh root@a1.example 'sudo sh -c …' | dotdash-manager adopt a1
```

It takes the server's keys as its group's, its `relay_seed` too, so every
relay keeps its id there and the `server/1` line it holds. It says which of
the group's devices keep their links, which are new to the server, and which
the server has but the group doesn't, which lose access at the next `sync`
unless you add them; a relay's client from 0.18 left in `vless_clients` is
dropped. It also names the server's desktops missing from the roster's
`desktops`, which would get CDN links at the next `sync` unless you add them
there. And it names each of the server's `subscription`, `cdn_hosts`,
`pools`, `direct` and `name` that the roster would change at the first
`sync`: with `subscription` left out of the roster, for one, every device's
subscription URL stops. Finish a [key rotation](#rotating-the-reality-key)
first: only the current key is taken. Once the manager has published, `adopt`
refuses, since it would change the keys on every machine again; `--force` when
that is meant.

Then join every machine as above, the running servers and relays included,
with no options: the script finds them installed and only points them at the
manager. Relays keep their own keys, name and nonce, so devices keep their
relay links too, and the lines in `relays` and `servers` stay what they are.
Join the relays before the servers: a server's document writes `relays` from
the relays' facts, so a relay that hasn't joined yet is left out of it, and
devices lose its links until it joins.

## Keep it current

```sh
dotdash-manager sync --dry-run   # what would change
dotdash-manager sync
dotdash-manager status --wait    # until every machine applied it
```

`sync` publishes only documents that changed, and renews the rest every three
days: a document expires after seven. Run it from a timer to keep it ahead of
that. A device added to a group's `devices` reaches its servers at the next
sync, and the relays a minute after they applied it, from the servers' lists;
one removed loses its access everywhere, each server within its next cycle
and each relay a minute after. The manager forgets its id at that sync, so a
device added back later gets a new one: new links and a new subscription URL,
and its old ones let no one in. The same goes for a canary's own id and a
client machine's proxy password.

## A device's link

Add the device's name to `devices`, then:

```sh
dotdash-manager sync
dotdash-manager status --wait     # every server and relay has it
dotdash-manager link phone --qr
```

`link` prints the device's subscription URLs, as the servers' `client-config`
does: the server's, unless `direct = false`, then the same through each
own-site relay its `pools` give it, which a device inside the restricted
network fetches from. A burnt relay or a waiting spare is left out, as at the
last `sync`. `--qr` adds a QR code for each, by `qrencode` if it is
installed. The URLs are the device's credentials: `link` prints them and
keeps them nowhere. With `subscription = false`, run `client-config` on a
server for the device's links.

When a device's link leaks, give it a new id:

```sh
dotdash-manager renew phone
dotdash-manager sync
dotdash-manager status --wait
```

`renew` prints the device's new URLs, which work once its servers applied
the `sync`. Its old links and URL stop once they have, and every relay a
minute later. The
device fetches its new links from the new URL, so send it that.

Before it uses a machine's facts, `sync` checks them. Facts no release
prints are refused: a value holding whitespace, a quote, a backslash, a brace
or a control character, or a field missing or of the wrong type. `sync` names
the machine and the field, and leaves the facts out. Two relays whose facts
name the same host don't move it in the pools when one burns or stands in.

When a machine's facts can't be read, or are refused, its last good facts
stand in for up to a day, and `sync` prints why, the read's error included. A
passing outage of the target, or a wrong `identity` file, then doesn't take a
relay off every device at once. After a day the machine is left out of every
document until a read succeeds, and `sync` says so in capitals.

The manager keeps what it made in `dotdash-state.json` beside the roster: the
shared keys, every device's id, the client machines' proxy passwords and each
machine's last good facts. It is
written with mode 0600 and holds every credential in the network:
[back it up](#back-up-the-state) like `authority.key`. One run at a time changes it: a run holds
`dotdash-state.lock` beside it, and another started meanwhile, such as a timer's
`sync` during a `rotate`, waits for it. `sync --dry-run` leaves it as it was.

With no state beside a roster that names a joined machine, every command but
`adopt` refuses: a new state would give every server new keys and cut every
device off. That's a checkout the state wasn't copied to, so copy it there.
To start over on new keys anyway, put `--new-state` before the command:

```sh
dotdash-manager --new-state sync
```

## Status

`status` prints a line per machine, then the topology:

```
machine  kind    release  document                                  health                facts  canaries
a1       server  0.19.0   applied 12                                5/5 up, row 12m ago   10m    reality ok, xhttp ok
b1       server  0.18.0   REFUSED 9 unmanageable: name, relay_seed  5/5 up, row 30m ago   30m    unwatched
r1       relay   0.19.0   applied 7                                 4/4 up, row 40m ago   20m    reality off, xhttp ok
r2       relay   0.19.0   pending 4, last fetch unreachable         STALE, row 4h10m ago  5h 0m  unwatched
c1       canary  0.18.0   applied 3                                 2/2 up, row 20m ago   20m    read 30m ago
r3       relay   -        not joined: run join r3                   -                     -      -

topology, from the facts the last sync read:
  server a1 (a): a1.example.net:443: reality, xhttp, mkcp 8447
  server b1 (b): b1.example.net:443: reality, xhttp
  relay r1: 203.0.113.5, site r1.example.net: reality, xhttp, hy2 443, cdn c.example.net; name r1; off=reality
    group a: live, a1.example.net ok; 14 devices, list 42 s old
    group b: DOWN, b1.example.net down; 3 devices, list 300 s old
  relay r2: 198.51.100.9, site www.example.org: reality; name r2; via r1 (reality); spare
    group a: not in its servers yet
  pool p: phone, 203.0.113.5
  canary c1 watches r1
```

- **release**: what the machine runs, and the release its channel staged, if
  one waits.
- **document**: what it did with the newest document published for it:
  `applied`, `REFUSED` with morzer's class and the names it refused, or
  `pending` until its next pull, every 15 minutes, with the last fetch's
  result when that failed. `sync off` or `not following the manager` is a
  machine that won't take one.
- **health**: how many of its services run, and how old its fleet row is.
  `STALE` is a row older than three hours.
- **facts**: how old the facts the last `sync` read are. Past a day, `sync`
  leaves the machine out of every document.
- **canaries**: each path, as its canaries found it at the last `sync`, and
  `BURNT` before them; for a canary, how old its last reading is.

Below the table come notes: a machine whose facts task failed.

The topology gives each group a relay serves its own line, as the relay's
facts say ([Health per group](relay/gateway.md#health-per-group)): `live`
while one of the group's servers serves the relay its device list, so the
group's devices get through it; `DOWN` while none answers; `REFUSED` while
they answer that they have no list for it (its `relay/1` line isn't in their
`relays` yet, or its `server/1` line is out of date); `starting` before its
first round; `not in its servers yet` until its document gives it the
group's line. Each group is its own: one down says nothing of the relay's
entry, which its canaries judge, nor of its other groups. A canary passing
while the relay says `b` is down means the entry is fine and `b`'s servers
or the way to them are not.

Under the relays' `device-addresses` profile, `status` ends with the devices
`sync` named in the last day ([Leaked links](#leaked-links)). They change no
exit code.

It reads each machine's own fleet row and the newest document on the target,
two morzer calls, and the rest from the state, so it prints no key, path or
id. It exits 1 when a document is refused, a machine doesn't follow the
manager, a row is stale or a service is down. A group's state changes no
exit code: it is from the facts the last `sync` read, from before the
documents it sent.
After a `sync`,
`status --wait` asks again every 30 seconds until every machine has applied
or refused its newest document, for up to 20 minutes (`--timeout`), and exits
1 if one is still pending. A timer's `sync` waits for it meanwhile.

## Burnt relays

Before every fleet publish, about hourly, each canary that follows the manager
reports whether each of its paths to the server or relay it watches gets
through. When every canary watching a relay got through none of its paths
three readings in a row, `sync` takes every path of that relay off in the
servers' `relay_flags`, and the relay out of their `pools` and of client
machines' subscription URLs, and says so. It stays in their `relays`: out of
them, the servers would no longer know its id, and its canaries could never
get through it again. A
reading counts only beside the newest of the other canaries watching the same
relay within 90 minutes, so a canary gone quiet can't hold the relay up with an
old success:

```
burnt: relay r1: its canaries got through none of its paths in 3 readings; devices get none of its links, and it leaves the pools, until a canary gets through again; its own fleet row (40m old) says it runs: blocked on the way, not down; replace it
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
- **A canary's clock may run ahead by ten minutes.** A reading stamped
  further ahead of the manager's clock doesn't count, so a canary whose clock
  is wrong can't burn a relay alone or keep it burnt.
- **Every relay at once is kept.** If every relay would be left out in the
  same sync, the manager keeps them all and says to check the canaries'
  network instead.
- **A burnt server is only reported.** Relays reach the servers, so leaving
  one out would cut them off.
- **A relay no canary watches is never judged.** Run canaries where devices
  are: [on a mobile line](canary/index.md#on-a-mobile-line).
- **A [CDN-only relay](server/cdn.md#the-cdns-origin-only) is judged by its
  CDNs alone.** Devices reach it through those, so its canaries'
  [checks of each](canary/index.md#a-relays-cdns) are its paths, and its own
  address, which no device gets, counts for nothing. It burns when none of its
  CDNs gets through, and a spare stands in as for any relay. While none of its
  canaries checks a CDN of it (a release from before CDN checks, or every name
  with a `cdn_extra`), it isn't judged, and `sync` says why.

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
but devices don't get it: every path of it is off in the servers'
`relay_flags`, and it is out of their `pools`. When
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
watching, one that burns or comes back, one that leaves the roster, a relay
turning CDN-only while no canary checks its CDNs (no longer judged, so a burn
ends there), a path going off or on (a CDN as `cdn:<name>`), a spare standing
in or waiting again. `report` reads that
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
has moved; a relay counts each as `<device>@<group>`, and the manager adds
that to the device. `sync` adds each device's bytes up by day, over the last 30 days.
It names a device whose day reached five times its median day and at least
2 GB, once it has 7 days to judge by:

```
phone-2: 14.2 GB on 2026-12-03, against 0.4 GB on its usual day: if its link may have leaked, renew phone-2 and sync
```

`sync` prints yesterday's and today's; `report` ends with the last 30 days'.
A link passed around shows this way: its device suddenly moves far more than
it ever did. A long video call or a big download can too, so ask before
renewing it. Only counts reach the manager, never an address. They
are an hour behind at most, as the facts refresh hourly. A server or relay
that restarts loses only what it counted since the last refresh.

With the `device-addresses` profile on the relays
([relay](relay/operations.md#devices-at-several-addresses)), their facts
also carry how many addresses each device is connected from when they
refresh, an IPv6 /64 counted once. `sync` names a device at three or more
addresses at once on one relay, or on two relays whose facts refreshed within
15 minutes of each other:

```
phone-2: 4 addresses at once on relay r1 at 2026-12-03 14:05 UTC: if its link may have leaked, renew phone-2 and sync
phone-2: on relays r1, r2 at once at 2026-12-03 14:07 UTC: if its link may have leaked, renew phone-2 and sync
```

`sync` prints each once, from the facts that first show it; `status` ends
with the last day's, and `report` with the last 30 days'. A phone shows one
or two addresses. A device named once can be innocent: it moved from one
relay to the other within those 15 minutes, or its app kept both open from
one address, which counts alone can't tell from two places. A link passed
around shows again and again, within days. Again, only counts reach the
manager, and renewing stays yours.

## Certificates

The facts of servers and relays carry how many days their site's certificate
has left (`cert_days`). Under 14, `sync` says so, and `report` too from the
facts the last `sync` kept:

```
certificate: relay r1: its site's certificate runs out in 9 day(s): renewal is failing, check its ACME (for acme-dns, that it runs and answers)
```

Renewal starts well before that, so it has been failing. Once the
certificate runs out, XHTTP on the site, Hysteria2 and the CDN links stop
while REALITY keeps working, and canaries take those paths off as if they
were blocked. A machine whose facts don't say, such as one on an earlier
release, gets no warning.

## Rotating the REALITY key

`rotate` changes the servers' REALITY key with no device cut off, over their
second key ([Rotating the REALITY key](server/secrets.md#rotating-the-reality-key)),
in three steps, each published by the next `sync`. Every group rotates at
once, each to a next key of its own:

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
- **`swap`** refuses until, for each group, one of the canaries watching its
  servers has got REALITY through on its next key since `start`, and names
  the groups none has. It then makes each next key its servers' key and
  keeps the old one second. Subscriptions, client machines and relays move to
  the new key, and devices still on the old one keep getting in. A relay
  keeps its last document until a group's servers have applied the swap.
- **`finish`** refuses for a week after `swap`, the devices' time to fetch
  their subscriptions or get new links. It then turns the old key off, and
  removes it from the servers' secret stores, so their later backups no longer
  hold it.
- `rotate` alone says where it stands. `--force` skips the canary check or
  the week, when you know better.

## Blocked paths

Short of burnt, a relay can lose one path while its others get through: its
REALITY port cut while XHTTP through its own site still answers, mKCP
dropped, or one path's connections frozen after their first few kilobytes,
which a canary's [freeze download](canary/index.md#what-it-checks) catches. When every canary watching a relay got through none of its readings
on one path three times in a row, and another path got through, `sync` puts
that path in the servers' `relay_flags` as `off=`, by the relay's name:

```
blocked: relay r1: reality got through for none of its canaries in 3 readings; devices get its other paths until one gets through again
```

Devices then get only its other links through it, its CDN links included, at
their next subscription refresh. A reading where the path gets through again
takes it off. The relay's [CDNs](canary/index.md#a-relays-cdns) count as its
paths too: one that gets through keeps the relay from burning while its own
address is blocked.

- **A path blocked on every relay that has it is kept.** That's likelier the
  canaries' network refusing the transport than every relay losing it at
  once, so the manager says to check that network instead.
- **A server's blocked paths are only reported**, as a burnt server is.
- **A CDN in front of a relay goes off alone**, as `off=cdn:<name>`, while
  the relay's other paths get through: devices lose that CDN's links and keep
  the rest. It is one relay's, so it is never kept for being blocked on every
  relay. Check the CDN's settings and the relay's site.

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
  Its `relay_flags` line then gets `split` beside `off=reality`. A change
  there restarts no server's Xray, as one to `relays` would. Share links lose REALITY
  through it, as for any blocked path, while devices' Xray configs keep it,
  split. A relay with REALITY as its only path isn't burnt while its split
  hello gets through. A burnt relay stays out.

## What it leaves alone

The upstreams, ports, profiles, domains and anything else a machine alone
knows stay the operator's, set on that machine as before. A value the manager
sets is refused by `config set` on the machine while sync is on; `--force`
changes it until the next document.

A relay's own keys, `name` and `nonce` stay its own too: its facts carry
them, and the manager builds its `relay/1` line from them.

Give every server of a group the same profiles and transport ports, though:
each server's links and configs name the others with its own `https_port`,
XHTTP with REALITY, mKCP (port, header and opener) and Hysteria2 ports. `sync`
says when a group's servers that applied its keys differ in any of those.

## A relay's transports

Change them on the relay itself: a profile, a port, `cdn_hosts`, `name`, and
its firewall to match. Its facts carry its new line after the apply, and the
next `sync` puts that line in the `relays` of every group it serves; devices
get the new links at their next refresh. Nothing is edited on the servers. A
new `name` is a new id on every group, so that `sync` also gives the relay
new `server/1` lines, and it idles until both sides applied them. Which
parameters go into the line is in the
[relay reference](relay/reference.md#what-changes-the-relays-line);
`http_origin_from` doesn't, so a change to it needs nothing more. Then
`entry-check` on the relay says whether each entry works.

To undo a change, set the previous value again on the relay, and the next
`sync` does the rest. morzer's journal names a change but not the value it
replaced, so note it first:

```sh
sudo morzer config get cdn_hosts      # on the relay, before the change
```

## Back up the state

`dotdash-state.json` holds each group's keys and every device's id.
Lost, the next `sync` with `--new-state` gives every server new keys, and
every device new links and a new subscription URL. Keep a copy off the
operator's box after each change to the roster, encrypted to an age
recipient whose identity is kept elsewhere, such as the machines' recovery
key:

```sh
age -r age1… -o "dotdash-state-$(date +%F).json.age" dotdash-state.json
```

Keep `authority.key`, `authority.age` and `network.toml` with it: the first
two can't be made again, as every machine pins the key and encrypts its facts
to the identity. To restore, decrypt the copy beside `network.toml`. A state
a few changes old still has the shared keys; devices added since get new ids
at the next `sync`. A key rotated since, though, would go back to the old
key on every server, so take a copy after each `rotate` step too.

## A rebuilt machine

A machine installed afresh, at the same address or not, has a new
installation id, signing key and age identity. One brought back from its
backup (`installation import`) keeps its id, but has a new signing key and
age identity too. Either way the manager's documents don't decrypt there,
and `status` finds no verified row for it. [Join](#add-a-machine) it again
under the same name: on a machine installed already the script only points
it at the manager, `joined` replaces the id and key it kept, and the next
`sync` sends it its document. Take a roster entry's own `id` and `key` out
first, as they win.

- **A server** comes back with the manager's keys and devices, from its
  first document, so devices keep their links and subscription URLs.
- **A relay installed afresh** comes back with new keys and a new nonce, so
  its line and its id on every group change. The next `sync` puts its line
  in the servers' `relays` and their new `server/1` lines in its `servers`,
  and devices' subscriptions pick up its new links; links sent by hand have
  to be sent again. One [moved from its backup](relay/operations.md#move-a-relay)
  keeps its keys, its nonce and its line.

## A lost server

With the state, a server lost with no backup comes back with its group's
keys and `relay_seed`, so devices keep their links and subscription URLs and
relays their ids:

1. Bring up a new machine, and point the server's domain at it.
2. Join it under the server's name in the roster, with its domain and
   upstreams:

    ```sh
    dotdash-manager join a --domain a.example.net --upstreams ./upstreams \
      | ssh root@198.51.100.4 sh | dotdash-manager joined a
    ```

3. `dotdash-manager sync`, then `status --wait`. The server applies the
   manager's keys and devices; once its facts show them, the relays,
   canaries and client machines follow at the next `sync`.

Relays reach the server by its domain, so they reconnect once its DNS
points at the new address. Under a new domain, the next `sync` gives its
group's servers and every relay serving the group the new one, and devices
that fetch their subscription through a relay get links to it at their next
refresh.

## Moving to server groups

A manager from before server groups ran one set of servers, and its relays
by copies of every device. One with groups runs servers and relays of 0.19
or later: a relay of 0.19 refuses the documents of the manager before, and
one of 0.18 those of this one. To move a network the manager already runs:

1. **The servers first**, to 0.19, with the manager of before still running:
   they take its documents, and read the relays' lines of 0.18 for one
   release.
2. **Then this manager, its roster and the relays.** Install the manager of
   the servers' release, and move the roster's `devices` into a `[[group]]`,
   named as the servers should be (it becomes their `name`): the manager
   refuses `devices` at the top, and says so, and the manager of before
   refuses `[[group]]`. The state's keys become the first `[[group]]`'s, so
   its servers keep theirs. Then `sync`, and update the relays to 0.19 right
   after. From that `sync` a relay of 0.18 is in no group's `relays`, and its
   client leaves `vless_clients` (`sync` says it waits for its update), so
   devices have only the servers' own links until it is updated: none with
   `direct = false`. An updated relay comes up idle, and the next `sync`
   gives the servers its `relay/1` line and it its `servers`; `status` then
   shows its groups `live`.

Its first `sync` gives the servers `name`, `relay_seed` and `relay_flags`:
the servers derive relays' ids now. A network set up by hand moves to 0.19
by hand, one relay at a time and with no gap
([Moving from 0.18](relay/gateway.md#moving-from-018)), and then to the
manager as in [Moving a running network](#moving-a-running-network).
