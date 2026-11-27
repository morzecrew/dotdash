# Parameters

| Name | Default | |
| --- | --- | --- |
| `upstream_mode` | `failover` | how the [upstreams](upstreams.md#order-and-modes) lines share the traffic: `failover` (the first that answers), `fastest` or `balance` |
| `upstream_pin` | `none` | the `name=` of the line that goes first; under `ipv6=separate`, a second name pins the IPv6 lines |
| `upstream_udp` | `false` | carry UDP through the upstreams, every one of which must carry it (WireGuard, OpenVPN, SOCKS5 with UDP ASSOCIATE); otherwise dropped |
| `https_port` | `443` | host port for REALITY and the site; devices dial it too, unless `entry_port` |
| `http_port` | `80` | host port for the site's plain HTTP: the ACME HTTP-01 check and the redirect to HTTPS |
| `listen` | empty | host address for `https_port` and `http_port`: empty for every address, IPv4 and IPv6; `0.0.0.0` for IPv4 alone; `127.0.0.1` [beside your own web server](shared-machine.md) |
| `entry_port` | `none` | the port devices, relays and the canary dial, when a web server of your own passes the domain through to `https_port`; `none` for `https_port` |
| `xdns_domain` | `t` | tunnel zone (`xdns`); a name with no dot is under the domain |
| `xdns_bind` | `0.0.0.0` | host address for UDP/53 |
| `hello_split` | `false` | split the ClientHello of devices' REALITY links to these servers into small TLS records, in the Xray config they get (`client-config --full`, the subscription's JSON); against a block by SNI. `dotdash-manager` sets it ([A name blocked by SNI](../manager.md#a-name-blocked-by-sni)) |
| `reality_second_key` | `false` | accept the second REALITY key (`reality_key_second`) beside `reality_key`, to [rotate it](secrets.md#rotating-the-reality-key) with no device cut off |
| `metrics_textfile` | `/var/lib/prometheus/node-exporter` | with the `metrics` profile, the node exporter's textfile directory, writable by 65532 ([Metrics](operations.md#metrics)) |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies get lost |
| `xdns_tti` | `50` | milliseconds between the tunnel's sends, on the server and in devices' configs; raise it if resolvers start refusing the queries |
| `xdns_resolvers` | three public resolvers | the resolvers devices' tunnel asks, comma-separated `udp://`, `tcp://` or DoH `https://` URLs, its queries spread evenly over them; where only the network's own resolver answers, put its address here |
| `xhttp_reality_port` | `8443` | port for XHTTP with REALITY; not `https_port` or `http_port` |
| `kcp_port` | `8447` | UDP port for [mKCP](mkcp.md); not 53 with the DNS tunnel |
| `kcp_header` | `dtls` | what mKCP's packets start with: `dtls`, `srtp`, `utp`, `wechat`, `wireguard` or `none` |
| `kcp_open` | `none` | an opener before mKCP's flow: `quic` sends a QUIC-Initial-shaped packet first, `none` nothing ([mKCP](mkcp.md)) |
| `hysteria2_port` | `443` | UDP port for [Hysteria2](hysteria2.md); not `kcp_port`, nor 53 with the DNS tunnel |
| `hysteria2_up` | `0` | Mbit/s Hysteria2's Brutal sends each device at, for one that asks; `0` keeps BBR |
| `tcp_congestion` | `bbr` | TCP congestion control toward devices, in the gate's own namespace: `bbr` keeps its pace through a lossy last mile; `cubic` for a kernel without `tcp_bbr`. The gate also probes each connection's path MTU, so a link that drops large packets slows a download rather than stalling it, and holds at most 128 KiB unsent per connection |
| `log_level` | `error` | Xray error log; `warning` and below name failed destinations |
| `probe_url` | `https://www.gstatic.com/generate_204` | fetched through the upstreams, and through each line every 10 s; an answer slower than 1.5 s counts as none |
| `probe_expect` | `.*` | regex the response must match, such as the exit IP |
| `probe6_url` | `http://api6.ipify.org` | IPv6-only URL fetched through the IPv6 lines, with `ipv6=separate` |
| `resolve` | `gateway` | `gateway`: this server resolves over `dns_resolver`; `upstream`: the upstream proxies see hostnames (no WireGuard, OpenVPN or `direct` line then) |
| `ipv6` | `allow` | `allow`: IPv6 leaves like the rest; `separate`: through the [`group=ipv6` lines](upstreams.md#ipv6) alone; `block`: no IPv6 destination leaves, names resolve to IPv4 only, so dual-stack sites still work (with `resolve=upstream`, the upstream resolves names itself) |
| `dns_resolver` | `https://1.1.1.1/dns-query` | DoH server for `resolve=gateway`; `https://` only |
| `subscription` | `false` | a subscription URL per device |
| `happ_routing` | `none` | with `subscription`, a routing profile in Happ's own JSON, sent with every subscription ([Happ's routing](devices.md#subscriptions)) |
| `exit_ipv4_url` | `http://api4.ipify.org` | with `subscription`, what the subscription's name asks, through the upstreams every ten minutes, for the exit's IPv4 address: plain HTTP answering with the caller's address alone |
| `exit_info_url` | `http://ipinfo.io` | with `subscription`, where the name asks `<url>/<address>/country` for the exit's country, whose flag goes before the address |
| `cert_issuer` | `acme` | `acme` (Let's Encrypt), `acme-dns` (Let's Encrypt over a DNS-01 check handed to acme-dns, for a [wildcard](certificates.md) that keeps the name out of certificate logs) or `internal` (offline machines) |
| `cover` | `pages` | what the [cover site](cover-site.md) serves past your own files in `/srv/dotdash`: `pages`, the bundled page, or your app's URL, such as `http://cover-app:8080` on the network `dotdash_edge` or `http://host.docker.internal:8080` for one published on the host |
| `servers` | `self` | servers sharing these keys, comma-separated |
| `cdn_hosts` | `none` | the names of local [CDNs](cdn.md#a-local-cdn-for-restricted-networks) in front of this server, comma-separated; a link through each |
| `cdn_extra` | `none` | `<name> <JSON object>` for each CDN name that asks for [XHTTP settings of its own](cdn.md#a-cdn-that-fetches-in-plain-http), the object as the CDN gives it; links and outbounds through that name carry it in place of dotdash's |
| `name` | `none` | this server group's name, 1 to 16 lowercase letters and digits starting with a letter, the same on every server in `servers`: what relays know these servers by, and what their own links are named by in place of `server`; devices' apps show it, so pick an opaque one. `relay-config` needs it |
| `relays` | a comment | one line per [relay](../relay/install.md), as its `relay-entry` prints it: `relay/1 <name> <nonce> <host> <site> <public key> <short id> <encryption>`, then `xhttp=<path>`, `kcp=<port>,<header>,<seed>`, `hy2=<port>`, `cdn=<name>[,<name>]`, `cdnpath=<path>`, `origin=…` and `cdn-only` where the relay has them. The relay comes in by an id these servers derive from `relay_seed` and its name and nonce, which [`relay-config -- <name>`](#a-relays-server1-line) prints it; deleting its line revokes it. For this release the lines of the one before, `<host> <site> <public key> <short id> <encryption> …` with `own-site <path>`, `name=`, `off=` and `standby`, still work, their relays coming in by their clients in `vless_clients` |
| `relay_flags` | a comment | one `<name> <flag>...` line per relay that needs one: `off=<path>[,<path>]` (`reality`, `xhttp`, `mkcp`, `hysteria2`, or `cdn:<name>` for one CDN in front of it) leaves out paths its canaries find [blocked](../manager.md#blocked-paths), `split` keeps REALITY through it with its hello split, and `standby` makes it the [last resort](../relay/install.md#5-on-the-server-add-the-line-to-relays), unchecked. A change restarts no Xray, as an edit to `relays` does |
| `pools` | a comment | one `<pool> <member>...` line per [pool](devices.md#pools), the members device names, relay hosts and CDN hosts |
| `direct` | `true` | `false`: no server's address in devices' links, configs or subscriptions, only [relays and CDN hosts](devices.md#keeping-the-servers-out-of-devices-links) |
| `openflux_channels` | a comment | with the `openflux` profile, one `<device> <kind>[=<link>] ...` line per device that gets an [OpenFlux](openflux.md) channel |
| `call_provider` | `none` | with the `openflux` profile, `tm`: a bare `tm` in `openflux_channels` gets a call made through the provider's API with `call_token` ([Calls made for you](openflux.md#calls-made-for-you)) |

Set one with `sudo morzer config set <name>=<value>`, unset it with
`sudo morzer config unset <name>`, edit `relays`, `relay_flags`, `pools`, `cdn_extra`, `happ_routing` or `openflux_channels`
with `sudo morzer config edit <name>`. A `relays` or `cdn_extra` line
devices would lose, or lose a field of (a malformed field, an extra Xray
refuses), fails the change that brings it, naming its line and field, and
morzer puts the old value back: the `lists` health check, which `doctor` runs
too. A field this release doesn't know, as a newer relay's line may carry, a
name two lines of before share, a `relay_flags` line naming no relay, or a
pool member that names nothing is only a warning. Two `relay/1` lines with one
name, ignoring case, or one whose relay's client name, `relay-<name>`, a
device in `vless_clients` has, fail it: Xray would refuse them too.
`sudo morzer task run client-config --output -- --check` prints them all. Profiles (`installation.profile`): `xdns`,
`xhttp-reality`, `mkcp`, `hysteria2`, `openvpn` (for an [OpenVPN line](upstreams.md#openvpn)),
`warm` (for [warm connections](upstreams.md#warm-connections)),
`openflux` (for [OpenFlux](openflux.md), with `openflux_channels`),
combined with commas, such as `xdns,xhttp-reality`.

## A relay's server/1 line

With `name` set and the relay's `relay/1` line in `relays`, `relay-config`
prints the one line that relay keeps for these servers:

```sh
sudo morzer task run relay-config --output -- r1
server/1 s1 example.com,b.example.com 443 <public key> <short id> <encryption> <r1's id here>
```

Its hosts are `servers`, its port `entry_port` or `https_port`, then the keys
devices' links carry, the relay's id, and `xr=<port>,<path>` under the
`xhttp-reality` profile. The id is the relay's way in, so the line is as
secret as a link. Every server in `servers` prints the same line, as they
share `relay_seed`. Rotating `relay_seed` revokes every relay of the group at
once; each then needs its line printed again. For a relay of the release
before, which has no `relay/1` line, `relay-config -- <its client's name>`
prints what it did.

Each relay fetches its device list from these servers through its tunnel,
so a device added or deleted in `vless_clients` reaches the relay with no
copy by hand. The list is named by a token only the relay's id gives, and
only a relay's Xray user can ask for it: Xray hands names under
`sub.dotdash.internal` to Caddy's internal listener on port 8085, which is
never published, for those users alone, and blocks every other user asking
for such a name. The list holds every device's id and name and, with
`subscription` on, the first 12 hex characters of its subscription token,
by which the relay's own site passes a device's subscription on to these
servers. The public site never serves a list.
