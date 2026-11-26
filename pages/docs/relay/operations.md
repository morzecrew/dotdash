# Running a relay

The relay keeps copies of what it got from the server: the devices, and the
server's keys. Whatever changes one side has to reach the other.

## Devices

A device added to or deleted from the server's `vless_clients` has to
change on the relay too. After the change on the server, `relay-config`
prints the relay's new copy:

```sh
# on the server
sudo morzer task run relay-config --output -- relay
# on the relay: the vless_clients block of that output
sudo morzer secret set vless_clients <<'END'
…
END
```

A relay copy you forget rejects a device added on the server, and still lets
in one deleted there. To check, compare the digests: `relay-config` ends with
the devices its copy lets in and their digest, and the relay's `relay-entry`
prints the same of its own copy:

```
The devices this copy lets in: 14, digest 3f9a1c2b.     # relay-config, on the server
The devices it lets in: 14, digest 3f9a1c2b.            # relay-entry, on the relay
```

The same digest means the same devices. The relay's facts carry it too, and
under the [manager](../manager.md#status), `status` says when a relay's list
isn't the one the manager sent. It is taken over the devices' ids alone, and
reveals none of them.

## Keys

| What changed | What to do |
| --- | --- |
| The server's `reality_key`, `vless_seed` or `reality_short_id` | Run `relay-config` again, and on the relay set `dotdash_public_key`, `dotdash_encryption` and `dotdash_short_id` from it. Until then the relay can't reach the server. |
| The relay's own keys (`secret rotate` on the relay) | Run `relay-entry` again, replace the relay's line in the server's `relays`, and send devices their links again (subscriptions pick them up). |
| The relay's address | The same: `relay-entry -- <new address>`, then replace the line. |

## Undo a change

morzer's journal names each change but not the value it replaced, so note
the old value before a change (`sudo morzer config get <name>`). To undo it,
set that value again. If the parameter goes into the relay's line
([which do](reference.md#what-changes-the-relays-line)), run `relay-entry`
and replace the line on every server too. Under the
[manager](../manager.md#a-relays-transports), the next `sync` does that.

## A site of its own, later

A relay set up with a borrowed site moves to one of its own in place. Point a
domain at it and open port 80, then:

```sh
sudo morzer config set installation.domains=relay.example.net
sudo morzer config set installation.profile=own-site
sudo morzer task run relay-entry --output -- 198.51.100.7
```

The site in the line changes and the line gains `own-site`, so replace the
relay's line in the server's `relays`, and send devices their links again
(subscriptions pick them up), with the subscription URL through the relay for
those inside the restricted network.
`sudo morzer config unset installation.profile` goes back to the borrowed
site.

## Servers

The relay goes to every server in `dotdash_servers` and uses whichever
answers fastest. With a [new server](../server/several-servers.md) sharing
the keys:

```sh
sudo morzer config set dotdash_servers=example.com,b.example.com
```

Under `own-site`, `sudo morzer apply` afterwards: the site fetches
subscriptions from these servers, and only an apply restarts it with the new
list.

## Through another relay

A relay on an address you can't afford to lose can go through another relay
instead of to the servers. Its one connection out is then to that relay,
which carries it on as one of its devices, and the servers never see its
address.

1. On the server, a client for this relay in `vless_clients`, and the relay
   installed from `relay-config`, as for any relay.
2. The other relay lets this one in by that client's id. Its copy of
   `vless_clients` holds every client but its own: after adding this relay's
   client on the server, set the other relay's copy again from its own
   `relay-config` ([Devices](#devices)).
3. On the other relay, its line:

    ```sh
    sudo morzer task run relay-entry --output -- <its address>
    ```

4. On this relay, that line in `via`:

    ```sh
    sudo morzer config edit via
    ```

The apply's health check goes through the other relay, and morzer rolls back
a line it can't get through. With two lines, it uses whichever relay answers
fastest, so one going down doesn't cut it off.

How it reaches the other relay, `via_link`:

- `reality` (the default): REALITY with Vision, one connection for each of
  its devices' connections, as a device's `reality` link to a relay.
- `xhttp`: XHTTP through the other relay's own site, under that site's
  certificate, a few connections reused across all its devices, as a
  device's `xhttp` link to a relay. To whoever watches this relay, that is a
  machine fetching from a website, rather than as many connections as its
  devices make. The other relay needs `own-site`, and its line then carries
  `own-site <path>`, which this one needs.

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
and leave this one idle; once it doesn't, they go through this one. Put both
relays' lines in the server's `relays`, the other relay's first: devices get
the other relay's links and this one's, which go through it. A
[`name`](reference.md) on each says which is which in the apps, such as
`name=y` on the other relay and `name=y-via-x` on this one: `y · reality`,
`y · xhttp`, `y-via-x · reality`. In apps where you pick a link, pick the
other relay's and keep this one's for when they stop working; Xray configs
that pick the fastest pick the shorter way while it works, though they check
every link every 30 seconds, this one's too.

- `dotdash_servers` and the server's keys stay as they are: under
  `own-site`, the site still fetches devices' subscriptions from the servers,
  through the other relay.
- Or the other relay has no line in the server's `relays`: then no device
  gets a link to it and only this relay knows its address, so its firewall
  can let in this relay alone (with `cert_issuer=acme-dns`, which needs no
  port 80). Either way, the server's firewall can let in the relays alone.
- Each relay on the way adds its round trip to every new connection.
- `dotdash_link=xhttp-reality` is a way to the servers only: with `via`,
  the link is `reality`.
- Devices added on the server go into this relay's copy as before. The other
  relay's copy needs this relay's client, and its own devices if any.

With the [manager](../manager.md), `via` in the relay's entry of
`network.toml` does all of this.

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
id confuse each other's backups. A relay whose links name its IP needs a new
line from `relay-entry` in the server's `relays`, and new links for devices.
Under the manager, the imported relay has a new signing key and age
identity: [join it again](../manager.md#a-rebuilt-machine).

## Watching it

`doctor` and each `apply` fetch `probe_url` through dotdash, so they fail
when the relay can't reach the server. Have them alert you:

```sh
sudo morzer notify target add https://hooks.example/morzer
```

What the relay can't see is whether devices reach it: only a machine on the
networks devices use can. A [canary on a mobile line](../canary/index.md#on-a-mobile-line)
checks the relay as it checks a server, with the commands `relay-entry` prints.

## Check each entry

`entry-check` tries each of the relay's entries as a device would, end to
end, and says why one fails:

```sh
sudo morzer task run entry-check --output
```

```
servers  ok: the relay reaches the servers, or the relays in via
reality  ok: a device's REALITY link under relay.example.net gets through
xhttp    ok: the site passes the XHTTP path on to Xray, under its own certificate
mkcp     ok: mKCP answers on UDP 8447
hy2      ok: Hysteria2 answers on UDP 443, under the site's certificate
cdn      not checked here: a CDN's half takes a fetch through it, which cdn-check on a server makes
door     FAIL: all 41 requests in the last hour refused, all from 172.19.0.1, Docker's own address: docker-proxy hides the CDN's (over IPv6, or with its userland proxy). Set http_origin_from=any, or listen=0.0.0.0 to publish the door on IPv4 alone
```

- **The entries.** An Xray client inside the relay dials each of its
  inbounds with the relay's own keys and the first device's id, and fetches
  `probe_url` through it, on to the servers. `servers` goes straight to the
  servers first: when it fails, every entry fails with it, and `doctor`
  says more. The site's TLS is pinned to the certificate Caddy holds, so a
  failure there names what Xray saw.
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
the `metrics` profile adds the relay's, in the same directory: its traffic per inbound and outbound, and with several servers its verdicts on each. Nothing is
counted per device. The exporters run as 65532, so the directory has to be
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

Every series also carries `product`. `rate(dotdash_inbound_bytes_total[5m])`
per inbound shows which transport devices use.

## Updates

As for the server: `sudo morzer self-update` when a release needs a newer
morzer, then `sudo morzer update --stage && sudo morzer update --to <version>`.
Unattended updates follow
`update.channel=oci://ghcr.io/morzecrew/dotdash-relay:stable`; see
[Operations](../server/operations.md#unattended-updates).
