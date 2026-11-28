# Running a relay

The relay keeps one line per server group, in `servers`, and each server
keeps the relay's line in `relays`. Its devices it fetches from each group's
servers by itself.

## Devices

Nothing to do on the relay. A device added to or deleted from its server's
`vless_clients` reaches the relay within a minute. A deleted device still
connected restarts the relay's Xray, which alone cuts its open connections;
every device's connections then drop once. The `servers` task gives each
group's device count and the digest of its list, and the facts carry the
same.

## Keys

| What changed | What to do |
| --- | --- |
| A server group's `reality_key`, `vless_seed` or `reality_short_id` | Run `relay-config -- <relay>` on one of its servers again, and replace that group's line in the relay's `servers`. Until then the group shows `down` there. |
| A group's `relay_seed` | The same, for every relay of the group: each has a new id there. |
| The relay's own keys (`secret rotate` on the relay) | Run `relay-entry` again, replace the relay's line in every server's `relays`, and send devices their links again (subscriptions pick them up). Its `servers` lines stay. |
| The relay's `nonce` or `name` | The same, then `relay-config` on one server of each group again, as the relay's id there changes: replace its `servers` lines. |
| The relay's address | `relay-entry -- <new address>`, then replace the line on every server. |

## Undo a change

morzer's journal names each change but not the value it replaced, so note
the old value before a change (`sudo morzer config get <name>`). To undo it,
set that value again. If the parameter goes into the relay's line
([which do](reference.md#what-changes-the-relays-line)), run `relay-entry`
and replace the line on every server too.

## A site of its own, later

A relay set up with a borrowed site moves to one of its own in place. Point a
domain at it and open port 80, then:

```sh
sudo morzer config set installation.domains=relay.example.net
sudo morzer config set installation.profile=own-site
sudo morzer task run relay-entry --output -- 198.51.100.7
```

The site in the line changes and the line gains `xhttp=`, so replace the
relay's line in every server's `relays`, and send devices their links again
(subscriptions pick them up), with the subscription URL through the relay for
those inside the restricted network.
`sudo morzer config unset installation.profile` goes back to the borrowed
site.

## Server groups

`servers` holds one `server/1` line per group, each as one of the group's
servers prints it with `relay-config -- <relay>`. To add a group: its
servers' `name`, the relay's line in their `relays`, then its line here.
To drop one, delete its line. Either way:

```sh
sudo EDITOR=nano morzer secret edit servers
```

Xray restarts on it, and every device's connections drop once. A line Xray
can't read keeps it from starting: `doctor` says so at once, and Xray's log
(`sudo docker compose -p dotdash-relay logs xray`) names the line.

A [new server](../server/several-servers.md) sharing a group's keys goes
into that group's line, which its `relay-config` prints with every server of
the group. The relay uses whichever of a group's servers answers fastest,
and the group stays live while one serves its list.

`server_link=xhttp-reality` reaches each group's servers over XHTTP with
REALITY, on the port and path the line's `xr=` gives, which a server under
its [`xhttp-reality`](../server/xhttp-reality.md) profile prints: a few
connections reused across devices, about 100 ms sooner to a page's first
byte for about twice the CPU on both machines. A line without `xr=` keeps
REALITY.

## Through another relay

A relay on an address you can't afford to lose can go through another relay
instead of to the servers. Its one connection out is then to that relay,
which carries it on as one of its own, and the servers never see its
address.

1. On the other relay, its line:

    ```sh
    sudo morzer task run relay-entry --output -- <its address>
    ```

2. On this relay, that line in `via`, before `servers`:

    ```sh
    sudo EDITOR=nano morzer secret edit via
    ```

3. On each server of each group, both relays' lines in `relays`. The other
   relay lets this one in because its group's list holds this relay's id; a
   group the other relay doesn't serve shows `down` here.

With two lines in `via`, it uses whichever relay answers fastest, so one
going down doesn't cut it off. `servers` then names the relays on the way
for each group.

How it reaches the other relay, `via_link`:

- `reality` (the default): REALITY with Vision, one connection for each of
  its devices' connections, as a device's `reality` link to a relay.
- `xhttp`: XHTTP through the other relay's own site, under that site's
  certificate, a few connections reused across all its devices, as a
  device's `xhttp` link to a relay. To whoever watches this relay, that is a
  machine fetching from a website, rather than as many connections as its
  devices make. The other relay needs `own-site`, and its line then carries
  `xhttp=<path>`, which this one needs.

On the `xhttp` leg, `via_fingerprint` sets the TLS client hello this relay
shows the other one. The default, `chrome`, mimics that browser, as the leg
has always done. A browser hello between two machines is itself a small
tell — an ordinary site is fetched by a server, not a phone — so for a relay
that only ever talks to the other relay, `none` fits better: it drops the
browser mimicry and uses Xray's own TLS stack, which looks like a server-side
HTTP client. `firefox`, `safari`, `edge`, `ios` and `android` pick other
browsers, and `random` a different one per connection. It changes nothing on
the `reality` leg or on the way to the servers.

### Both ways at once

While the other relay's address gets through, devices can reach it directly
and leave this one idle; once it doesn't, they go through this one. With
both relays' lines in the servers' `relays`, devices get the other relay's
links and this one's, which go through it, each named by its relay's name:
`y · reality`, `y · xhttp`, `y-via-x · reality`. In apps where you pick a
link, pick the other relay's and keep this one's for when they stop working;
Xray configs that pick the fastest pick the shorter way while it works,
though they check every link every 30 seconds, this one's too.

- Each relay on the way adds its round trip to every new connection.
- `server_link=xhttp-reality` is a way to the servers only: with `via`, the
  link is `via_link`'s.

## Move a relay

A relay whose links name its domain moves to a new machine, or a new address,
with a DNS change, and devices keep their links. It keeps its keys, which a
backup holds. Prepare when you set it up: keep the recovery key off the
machine, add a backup target, and set the `A` record's TTL to 300 s or less.

```sh
sudo morzer secret set backup_s3 < ./bucket.yaml   # the bucket's credentials
sudo morzer backup target add s3://bucket/dotdash-relay/<name> --credentials backup_s3   # a prefix of its own
sudo morzer backup                                  # one now; each update takes another
```

Then, on the new machine, after `bootstrap.sh`:

```sh
sudo morzer --product dotdash-relay installation import --from-backup \
  --target s3://bucket/dotdash-relay --credentials-file ./bucket.yaml \
  --identity ~/relay-recovery.key
sudo morzer update oci://ghcr.io/morzecrew/dotdash-relay:stable
```

Point the relay's domain at the new address, and open 443, and 80 under
`own-site`. Shut the old machine down: two live relays with one installation
id confuse each other's backups. The imported relay keeps its name and
nonce, so its id on every server and its `servers` lines stay. A relay whose
links name its IP needs a new line from `relay-entry` in every server's
`relays`, and new links for devices. Under the manager, the imported relay
has a new signing key and age identity:
[join it again](../manager.md#a-rebuilt-machine).

## Watching it

`doctor` and each `apply` check the relay's own machinery: Xray runs, and
its agent reached Xray within the last two minutes. They no longer say
whether a server group answers, which each group's state does
([Health per group](gateway.md#health-per-group)):

```sh
sudo morzer task run servers --output
```

Under the `metrics` profile, alert on `dotdash_group_live == 0`, and have
`doctor` alert on the machinery:

```sh
sudo morzer notify target add https://hooks.example/morzer
```

What the relay can't see is whether devices reach it: only a machine on the
networks devices use can. A [canary on a mobile line](../canary/index.md#on-a-mobile-line)
checks the relay as it checks a server, as a device of one group, with the
commands `relay-entry` prints.

## Check each entry

`entry-check` tries each of the relay's entries as a device of each live
server group would, end to end, a line per entry per group, and says why one
fails:

```sh
sudo morzer task run entry-check --output
```

```
servers@a        ok: a.example.com ok
reality@a        ok: a device's REALITY link under relay.example.net gets through
xhttp@a          ok: the site passes the XHTTP path on to Xray, under its own certificate
mkcp@a           ok: mKCP answers on UDP 8447
hy2@a            ok: Hysteria2 answers on UDP 443, under the site's certificate
servers@b        FAIL: b is down: b.example.com down (503 Service Unavailable); its entries are not checked, as every one fails with it (the servers task says more)
cdn              not checked here: a CDN's half takes a fetch through it, which cdn-check on a server makes
door             FAIL: all 41 requests in the last hour refused, all from 172.19.0.1, Docker's own address: docker-proxy hides the CDN's (over IPv6, or with its userland proxy). Set http_origin_from=any, or listen=0.0.0.0 to publish the door on IPv4 alone
```

- **The entries.** An Xray client inside the relay dials each of its
  inbounds with the relay's own keys, as the group's checker, a user the
  relay adds to each group with a random id, so no device's id is needed,
  and fetches `probe_url` through it, on to that group's servers. A group
  that is not live has its entries left out, as every one fails with it. The
  site's TLS is pinned to the certificate Caddy holds, so a failure there
  names what Xray saw.
- **The door.** Under `http-origin`, Caddy logs each request to the door,
  its address and status alone, never its path or headers, in memory, the
  newest megabyte or two. The check reads the last hour of it. No request at
  all is a firewall, or the CDN fetching another port. Every request refused
  from one private address is docker-proxy, which Docker puts in front of a
  port reached over IPv6: the door sees Docker's address instead of the
  CDN's, so only `http_origin_from=any` matches, or `listen=0.0.0.0` keeps
  the door to IPv4. Every request refused from other addresses is
  `http_origin_from` missing the CDN's ranges, or the CDN asking for
  another path. Only the CDN's gateways and scanners reach the door, never
  a device. The log empties whenever Caddy restarts, and no backup holds it.
- **What it can't see** is the way from devices' networks to the relay: its
  address, its ports and its firewall. A canary on such a network sees that.

## Metrics

With morzer's own metrics in the node exporter's textfile directory
([`metrics.textfile`](https://github.com/morzecrew/morzer/tree/main/pages/docs/operating)),
the `metrics` profile adds the relay's, in the same directory: its traffic
per inbound and outbound, its verdicts on each server, and each server
group's state. Nothing is counted per device. The exporters run as 65532, so the directory has to be
writable by it:

```sh
sudo setfacl -m u:65532:rwx /var/lib/prometheus/node-exporter
sudo morzer config set metrics_textfile=/var/lib/prometheus/node-exporter   # its default
sudo morzer config set installation.profile=metrics    # beside own-site or mkcp if you run them
```

| Metric | Labels | Value |
| --- | --- | --- |
| `dotdash_xray_up` | `role` | 1 when the exporter read Xray's counters |
| `dotdash_inbound_bytes_total` | `role`, `inbound`, `direction` | bytes through an inbound since Xray started |
| `dotdash_outbound_bytes_total` | `role`, `outbound`, `direction` | bytes through an outbound since Xray started |
| `dotdash_observatory_alive` | `role`, `outbound` | 1 when the last check got through a server |
| `dotdash_observatory_delay_seconds` | `role`, `outbound` | that check's time, while it gets through |
| `dotdash_xray_heap_bytes` | `role` | Xray's Go heap, beside its `GOMEMLIMIT` |
| `dotdash_group_live` | `role`, `group` | 1 while one of the group's servers serves the relay its list |
| `dotdash_group_devices` | `role`, `group` | the group's devices the relay lets in |
| `dotdash_group_list_age_seconds` | `role`, `group` | the age of the group's list the relay holds |

Every series also carries `product`. `rate(dotdash_inbound_bytes_total[5m])`
per inbound shows which transport devices use. Each server's outbound is
tagged `<group>-<n>`, so group names reach whoever scrapes the metrics.
Alert on `dotdash_group_live == 0`: morzer's own alerts fire only when the
relay's machinery fails.

## Devices at several addresses

A link passed around gets used from several places at once. The
`device-addresses` profile counts, for each device, how many addresses it is
connected from at that moment, so the [manager](../manager.md#leaked-links)
can name a device at three or more at once, or on two relays at once:

```sh
sudo morzer config set installation.profile=device-addresses    # beside the profiles you run
```

- **Only counts leave.** Xray keeps each device's addresses in memory while
  it has a connection open, with or without the profile: the gateway's agent
  needs them to spot a deleted device still connected. An address is gone
  once its last connection closes. The facts task reads them from Xray's API
  and keeps only the count. Nothing writes an address to disk, and the facts
  never carry one.
- **An IPv6 /64 counts once.** A phone's IPv6 addresses change, but stay
  inside its line's /64.
- **When it counts.** The facts refresh hourly, so a device counts only if
  it is connected right then. A phone shows one or two addresses: Wi-Fi and
  mobile data while it switches, or REALITY and XHTTP.
- **What it can't see.** XHTTP and CDN links reach Xray through the relay's
  own site, so they all count as one address, the site's. A link passed
  around on XHTTP alone looks like one device. Devices behind one mobile
  carrier's NAT can share an address too.

## Updates

As for the server: `sudo morzer self-update` when a release needs a newer
morzer, then `sudo morzer update --stage && sudo morzer update --to <version>`.
A relay of 0.18 moves to the gateway after its servers, by hand:
[Moving from 0.18](gateway.md#moving-from-018).
Unattended updates follow
`update.channel=oci://ghcr.io/morzecrew/dotdash-relay:stable`; see
[Operations](../server/operations.md#unattended-updates).
