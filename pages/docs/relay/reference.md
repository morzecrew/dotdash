# Relay reference

## Parameters

Set one with `sudo morzer config set <name>=<value>`.

| Name | Default | |
| --- | --- | --- |
| `site` | `none` | without the `own-site` profile, a site next to the relay, in its own network, on TLS 1.3 and HTTP/2: devices send its name, and probes get its handshake |
| `cover` | `pages` | with `own-site`, what the site serves past your own files in `/srv/dotdash-relay`: `pages`, the bundled page, or your [app](../server/cover-site.md#an-app-instead-of-pages)'s URL, such as `http://cover-app:8080` on the network `dotdash-relay_edge` or `http://host.docker.internal:8080` |
| `tunnel_host` | `none` | with `own-site`, one host a cover app may call through the tunnel at `http://caddy:8090`, with no TLS: Caddy sends it on as HTTPS inside the link to the servers or the relays in `via`, so this machine shows one TLS client, Xray's ([cover site](../server/cover-site.md#an-app-installed-with-morzer)) |
| `cert_issuer` | `acme` | with `own-site`, `acme` (Let's Encrypt, over port 80), `acme-dns` (a [wildcard](../server/certificates.md) over a DNS-01 check handed to acme-dns, the `acme_dns` secret) or `internal` (Caddy's own CA, for a machine the internet can't reach) |
| `entry_host` | `none` | the address devices reach the relay at, its IP without a domain, for `relay-entry` with no address and for `facts`; `none` under `own-site` is the relay's domain |
| `cdn_hosts` | `none` | with `own-site`, the names devices use for [local CDNs](../server/cdn.md#in-front-of-a-relay) in front of the relay, comma-separated; `relay-entry` adds them to the relay's line |
| `http_origin_port` | `8880` | with the `http-origin` profile, the host TCP port of its door, published at `listen`: where a [CDN that fetches in plain HTTP](../server/cdn.md#a-cdn-that-fetches-in-plain-http) fetches the relay |
| `http_origin_from` | `none` | with `http-origin`, the addresses the door answers, comma-separated IPs or CIDR ranges: the CDN's gateways; `any` answers every address, `none` no one. The door sees the address that connects to it: over IPv6, which Docker forwards from an address of its own, or behind a proxy of yours in front of the port, only `any` works |
| `http_origin_host` | `none` | with `http-origin`, the names devices reach that CDN at, comma-separated, each `<name>/<path>` where the CDN gives a path of its own; `relay-entry` adds it to the relay's line as `origin=`, and prints the `xhttpSettings` to give the CDN |
| `cdn_only` | `false` | `true`: devices get the relay's CDN links alone, none to its own address, so it stays the [CDNs' origin](../server/cdn.md#the-cdns-origin-only); `relay-entry` ends the line with `cdn-only`, and refuses it without `cdn_hosts` |
| `name` | `none` | a label of up to 24 letters, digits, dots, dashes or underscores that devices' links through the relay carry in place of `relay <n>`: `edge-1 · reality`. `relay-entry` ends the line with `name=`; a name an earlier line took goes by the number. Every device's app shows it, so pick one that says nothing about where the relay is hosted |
| `dotdash_servers` | none, given at `init` | the dotdash servers sharing one set of keys, comma-separated domains; the relay uses whichever answers fastest |
| `dotdash_port` | `443` | the servers' `https_port` |
| `dotdash_public_key` | none, given at `init` | the servers' REALITY public key, the `pbk` of their links |
| `dotdash_address` | `none` | where to connect when `dotdash_servers` names one server, such as its IP; `none` reaches each server by its name |
| `metrics_textfile` | `/var/lib/prometheus/node-exporter` | with the `metrics` profile, the node exporter's textfile directory, writable by 65532 ([Metrics](operations.md#metrics)) |
| `dotdash_link` | `reality` | how the relay reaches the servers: `reality`, a REALITY connection with Vision for each device's; `xhttp-reality`, XHTTP with REALITY on `dotdash_xhttp_reality_port`, connections reused across devices, about 100 ms sooner to a page's first byte for about twice the CPU here and on the server. Needs the servers' [`xhttp-reality`](../server/xhttp-reality.md) profile and the `dotdash_xhttp_path` secret, both of which `relay-config` prints |
| `dotdash_xhttp_reality_port` | `8443` | the servers' `xhttp_reality_port`, for `dotdash_link=xhttp-reality` |
| `via` | none | other relays to go through instead of the servers, one line each as its `relay-entry` prints it; with several, whichever answers fastest ([Through another relay](operations.md#through-another-relay)). Not with `dotdash_link=xhttp-reality` |
| `via_link` | `reality` | how the relay reaches those in `via`: `reality`, REALITY with Vision, a connection for each device's; `xhttp`, XHTTP through each one's own site under its certificate, connections reused across devices, for which each line has to carry `own-site <path>`, as `relay-entry` prints it under `own-site` |
| `via_fingerprint` | `chrome` | the TLS client hello the `xhttp` `via` leg shows the relay it goes through (`via_link=xhttp` only; the `reality` leg and the way to the servers are unaffected): `chrome`, `firefox`, `safari`, `edge`, `ios`, `android` mimic that browser; `none` uses Xray's own Go TLS stack, which looks like a server-side HTTP client rather than a browser; `random` picks a browser per connection |
| `probe_url` | `https://www.gstatic.com/generate_204` | what the health check fetches through dotdash; any 2xx is healthy |
| `tcp_congestion` | `bbr` | TCP congestion control toward devices, in Xray's own namespace: `bbr` keeps its pace through a lossy last mile; `cubic` for a kernel without `tcp_bbr`. Xray also probes each connection's path MTU and holds at most 128 KiB unsent per connection, and gives its link to a server up after 15 s of unacknowledged data |
| `ipv6` | `allow` | `block`: IPv6 destinations end at the relay and never reach a server; names go on |
| `https_port` | `443` | host port for REALITY; devices always dial 443, so another is for [your own web server](../server/shared-machine.md) passing the relay's name through |
| `http_port` | `80` | with `own-site`, host port for the site's plain HTTP, the ACME HTTP-01 check |
| `listen` | empty | host address for `https_port` and `http_port`: empty for every address, IPv4 and IPv6; `0.0.0.0` for IPv4 alone; `127.0.0.1` beside your own web server |
| `kcp_port` | `8447` | with `mkcp`, the UDP port devices reach the relay's mKCP on |
| `kcp_header` | `dtls` | with `mkcp`, what its packets start with, as the server's [`kcp_header`](../server/mkcp.md) |
| `kcp_open` | `none` | with `mkcp`, an opener in front of the flow, as the server's `kcp_open`: `quic` sends a packet shaped like a QUIC Initial first. `relay-entry` adds it to the relay's line, so devices' links through the relay match |
| `hysteria2_port` | `443` | with `hysteria2`, the UDP port devices reach the relay's Hysteria2 on |

### What changes the relay's line

The servers know the relay by its line in `relays`. After changing any of
these, print it again with `relay-entry` and replace it on every server
(under the [manager](../manager.md), its next sync does that from the
relay's facts): `entry_host` (or the address after `--`), `site`, the relay's
domain under `own-site`, the `own-site`, `mkcp`, `hysteria2` and
`http-origin` profiles, `kcp_port`, `kcp_header`, `kcp_open`,
`hysteria2_port`, `cdn_hosts`, `http_origin_host`, `cdn_only`, `name`, and a
rotated `reality_key`, `reality_short_id`, `vless_seed`, `xhttp_path`,
`cdn_xhttp_path` or `kcp_seed`. The rest change nothing on the servers:
`http_origin_port` (the CDN needs it, the servers don't), `http_origin_from`,
`cover`, `tunnel_host`, `cert_issuer`, `https_port`, `http_port`, `listen`,
`via`, the `dotdash_*` parameters and the rest.

## Profiles

`installation.profile=own-site`: the relay serves a site of its own under its
domain (`--domain` at `init`, or `installation.domains`), and REALITY hands it
every connection without the relay's keys. It publishes port 80 too, for the
certificate. The site also serves devices their subscriptions, fetched from
the servers through the relay's tunnel, and XHTTP on the secret path
`xhttp_path`, which `init` generates. With `cdn_hosts` set, `relay-entry`
ends the relay's line with `cdn=<name>,...` and `cdnpath=<path>`, and the
server gives each device a `relay · cdn` link through each, by a secret path
of the CDNs' own (`cdn_xhttp_path`, generated too) that a CDN reading the
requests never learns the other from
([CDN in front of a relay](../server/cdn.md#in-front-of-a-relay)). See
[Set up a relay](install.md#1-pick-the-site).

REALITY hands the site each connection with the visitor's address (a PROXY
header), so a cover app sees each visitor's own address in
`X-Forwarded-For`, not Xray's, and its per-address limits work. Visitors
over the Hysteria2 port's HTTP/3 still show Xray's, and where Docker relays
the port itself, as for IPv6 without its NAT or behind a web server of your
own on this machine, every visitor shows as Docker's bridge address. A
subscription token the servers don't have gets the site's own answer, as any
other path does.

`installation.profile=own-site,hysteria2`: the relay serves
[Hysteria2](../server/hysteria2.md) on UDP `hysteria2_port` too, under its own
site's certificate, each device's UUID its login, and carries it on to the
servers like REALITY. It needs `own-site`, whose certificate it serves:
without it the profile is refused. `relay-entry` then ends the relay's line
with `hy2=<port>`, from which the server gives each device a
`relay · hy2` link. Open the UDP port in the provider's firewall, and
replace the relay's line on the server after turning it on.

`installation.profile=own-site,http-origin`: the relay's Caddy also listens
in plain HTTP on `http_origin_port`, a door for a
[CDN that fetches in plain HTTP](../server/cdn.md#a-cdn-that-fetches-in-plain-http).
It answers the addresses in `http_origin_from` alone, on the CDNs' path
alone, which it passes on to Xray's XHTTP inbound; everyone else gets a 404.
It needs `own-site`, whose Caddy is the door: without it the profile is
refused. `relay-entry` then ends the relay's line with `cdnpath=<path>` and
`origin=<http_origin_host>`, from which the server gives each device a
`relay · cdn` link through that name. Where the CDN gives several names,
set them all, comma-separated: each gets a link of its own, `cdn 1`,
`cdn 2` and on. A name the CDN gives with a path of its own takes it after
the name, `<name>/<path>`, and its settings go in the server's `cdn_extra`
([A CDN that fetches in plain HTTP](../server/cdn.md#a-cdn-that-fetches-in-plain-http)).

`installation.profile=mkcp` (with a site of its own: `own-site,mkcp`): the
relay serves [mKCP](../server/mkcp.md) on UDP `kcp_port` too, under its own
`kcp_seed`, and carries it on to the servers like REALITY. `relay-entry` then
ends the relay's line with `kcp=<port>,<header>,<seed>`, from which the server
gives each device a `relay · kcp` link. Open the UDP port in the
provider's firewall, and replace the relay's line on the server after turning
it on.

`installation.profile=device-traffic` (with any of the others): the relay
counts the bytes each device moves through it, and its facts carry the counts
to the authority hourly, for the [manager](../manager.md#leaked-links). The
server counts the relay as one client, so a relay's devices are counted here.
The facts task, and with it `relay-entry`, then runs in Xray's namespace, and
starts Xray if it is down.

## Secrets

`init` generates the relay's own keys; the rest come from the server's
`relay-config`.

| Name | Generated | |
| --- | --- | --- |
| `vless_clients` | no | the devices the relay lets in, one `<uuid> [name [desktop|mobile]]` per line |
| `dotdash_id` | no | the id the relay uses on the server, its line in the server's `vless_clients` |
| `dotdash_encryption` | no | the `encryption=` value of the server's links |
| `dotdash_short_id` | no | the `sid=` value of the server's REALITY links |
| `vless_seed` | yes | the seed the relay's VLESS Encryption key pair derives from |
| `reality_key` | yes | the relay's REALITY private key |
| `reality_short_id` | yes | the relay's REALITY short id |
| `kcp_seed` | yes | the key the relay's mKCP packets are encrypted under, with `mkcp` |
| `xhttp_path` | yes | with `own-site`, the secret path the site routes to Xray's XHTTP inbound |
| `cdn_xhttp_path` | yes | with `own-site`, the secret path CDNs in front fetch XHTTP by, apart from `xhttp_path` |
| `dotdash_xhttp_path` | no | with `dotdash_link=xhttp-reality`, the `path=` of the servers' XHTTP links, from `relay-config` |
| `acme_dns` | no | with `cert_issuer=acme-dns`, the [acme-dns](../acme-dns.md) registration as JSON |

## Tasks

| Task | |
| --- | --- |
| `relay-entry --output -- <address>` | the relay's line for the server's `relays`, and how a canary checks the relay; with no address, at `entry_host` |
| `entry-check --output` | each of the relay's entries checked end to end as a device reaches it, and the `http-origin` door by its log, a line each with why it fails ([Check each entry](operations.md#check-each-entry)) |
| `facts --output` | the same line as JSON, which the relay publishes to an authority it [follows](../server/operations.md#managed-from-elsewhere); under `own-site` also `cert_days`, the whole days left on the site's certificate; and `clients`, how many devices it lets in and their [digest](operations.md#devices) |
