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
# optional: every server's cdn_extra, by CDN name (A CDN that fetches in plain HTTP)
cdn_extra = { "edge.example.net" = { uplinkHTTPMethod = "GET", xPaddingObfsMode = true } }

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
| a machine's (its `credentials`) | the target | `state/<product>/<installation-id>/`, and each backup's manifest | `fleet/<product>/<installation-id>/` (its row and facts), and its backups | none |

The product is `dotdash`, `dotdash-relay`, `dotdash-canary` or
`dotdash-client`; the installation id is the one `joined` kept, which
`morzer installation describe` on the machine prints.

Backups are the gap. morzer keeps every machine's backups at the target's
root, one directory per backup named by the second it was taken, so a
machine needs write there, beside the others' backups. Its retention lists
every backup at the root and prunes by count, whichever machine took them.
So:

- **Give machines no delete.** Retention then fails with a warning, and
  the bucket's own lifecycle rules expire old backups instead. With delete,
  a relay's retention prunes the servers' backups too, the shared
  credential included.
- **Turn on versioning or Object Lock** where the bucket has them, so a
  machine overwriting another's backup leaves the old version.

To move a joined machine to its own credential, name it in the roster and
run its `join` again: the script replaces the credential it holds.

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
`sync` unless you add them. It also names the server's desktops missing from
the roster's `desktops`, which would get CDN links at the next `sync` unless
you add them there. Finish a [key rotation](#rotating-the-reality-key)
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
dotdash-manager status --wait    # until every machine applied it
```

`sync` publishes only documents that changed, and renews the rest every three
days: a document expires after seven. Run it from a timer to keep it ahead of
that. A device added to `devices` reaches every server and relay at the next
sync; one removed loses its access everywhere, each machine within its next
cycle. The manager forgets its id at that sync, so a device added back later
gets a new one: new links and a new subscription URL, and its old ones let no
one in. The same goes for a relay's or canary's own id and a client machine's
proxy password.

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

`renew` prints the device's new URLs, which work once the servers applied
the `sync`. Its old links and URL stop once every server and relay has. The
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
machine  kind    release  document                           health                facts  canaries
a        server  0.18.0   applied 12                         5/5 up, row 12m ago   10m    reality ok, xhttp ok
r1       relay   0.18.0   REFUSED 9 unmanageable: via_link   4/4 up, row 40m ago   20m    reality off, xhttp ok
r2       relay   0.17.0   pending 4, last fetch unreachable  STALE, row 4h10m ago  5h 0m  unwatched
c1       canary  0.18.0   applied 3                          2/2 up, row 20m ago   20m    read 30m ago
r3       relay   -        not joined: run join r3            -                     -      -

topology, from the facts the last sync read:
  server a: a.example.net:443: reality, xhttp, mkcp 8447
  relay r1: 203.0.113.5, site r1.example.net: reality, xhttp, hy2 443, cdn c.example.net; name edge-1; off=reality
  relay r2: 198.51.100.9, site www.example.org: reality; via r1 (reality); spare
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

Below the table come notes: a machine whose facts task failed, and a relay
whose device list, by the digest its facts carry, isn't the one the manager
sent it, which a hand edit on the relay does.

It reads each machine's own fleet row and the newest document on the target,
two morzer calls, and the rest from the state, so it prints no key, path or
id. It exits 1 when a document is refused, a machine doesn't follow the
manager, a row is stale, a service is down or a relay's device list differs.
After a `sync`,
`status --wait` asks again every 30 seconds until every machine has applied
or refused its newest document, for up to 20 minutes (`--timeout`), and exits
1 if one is still pending. A timer's `sync` waits for it meanwhile.

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
has moved. `sync` adds each device's bytes up by day, over the last 30 days.
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
that path on the relay's line as `off=`:

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
- **So is a CDN blocked while the relay's other paths get through.** `off=`
  takes no CDN, so devices keep its links; check the CDN's settings and the
  relay's site.
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
  split. A relay with REALITY as its only path isn't burnt while its split
  hello gets through. A burnt relay stays out.

## What it leaves alone

The upstreams, ports, profiles, domains and anything else a machine alone
knows stay the operator's, set on that machine as before. A value the manager
sets is refused by `config set` on the machine while sync is on; `--force`
changes it until the next document.

Give every server the same profiles and transport ports, though: each server's
links and configs name the others with its own `https_port`, XHTTP with
REALITY, mKCP (port, header and opener) and Hysteria2 ports. `sync` says when
the servers that applied the keys differ in any of those.

## A relay's transports

Change them on the relay itself: a profile, a port, `cdn_hosts`, `name`, and
its firewall to match. Its facts carry its new line after the apply, and the
next `sync` puts that line in every server's `relays`; devices get the new
links at their next refresh. Nothing is edited on the servers. Which
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

`dotdash-state.json` holds the keys the servers share and every device's id.
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
- **A relay installed afresh** comes back with new keys of its own, so its
  line changes. The next `sync` puts it in the servers' `relays`, and
  devices' subscriptions pick up its new links; links sent by hand have to
  be sent again. One [moved from its backup](relay/operations.md#move-a-relay)
  keeps its keys and its line.

## A lost server

With the state, a server lost with no backup comes back with the same keys,
and devices keep their links and subscription URLs:

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
points at the new address. Under a new domain, the next `sync` gives every
server and relay the new one, and devices that fetch their subscription
through a relay get links to it at their next refresh.
