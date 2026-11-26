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
| `relays` | a comment | one `<host> <site> <public key> <short id> <encryption>` line per [relay](../relay/install.md), as its `relay-entry` prints it, with `own-site <path>`, `kcp=<port>,<header>,<seed>`, `hy2=<port>`, `cdn=<name>[,<name>]` and `name=<label>` after it where the relay has them; `off=<path>[,<path>]` (`reality`, `xhttp`, `mkcp`, `hysteria2`, or `cdn:<name>` for one CDN in front of it) leaves out paths its canaries find [blocked](../manager.md#blocked-paths), and `standby` makes it the [last resort](../relay/install.md#5-on-the-server-add-the-line-to-relays), unchecked |
| `pools` | a comment | one `<pool> <member>...` line per [pool](devices.md#pools), the members device names, relay hosts and CDN hosts |
| `direct` | `true` | `false`: no server's address in devices' links, configs or subscriptions, only [relays and CDN hosts](devices.md#keeping-the-servers-out-of-devices-links) |
| `openflux_channels` | a comment | with the `openflux` profile, one `<device> <kind>[=<link>] ...` line per device that gets an [OpenFlux](openflux.md) channel |
| `call_provider` | `none` | with the `openflux` profile, `tm`: a bare `tm` in `openflux_channels` gets a call made through the provider's API with `call_token` ([Calls made for you](openflux.md#calls-made-for-you)) |

Set one with `sudo morzer config set <name>=<value>`, unset it with
`sudo morzer config unset <name>`, edit `relays`, `pools`, `cdn_extra`, `happ_routing` or `openflux_channels`
with `sudo morzer config edit <name>`. A `relays`, `pools` or `cdn_extra` line
devices would lose, or lose a field of (a malformed field, a pool member that
names nothing, an extra Xray refuses), fails the change that brings it, naming
its line and field, and morzer puts the old value back: the `lists` health
check, which `doctor` runs too. `sudo morzer task run client-config --output
-- --check` prints every such line. Profiles (`installation.profile`): `xdns`,
`xhttp-reality`, `mkcp`, `hysteria2`, `openvpn` (for an [OpenVPN line](upstreams.md#openvpn)),
`warm` (for [warm connections](upstreams.md#warm-connections)),
`openflux` (for [OpenFlux](openflux.md), with `openflux_channels`),
combined with commas, such as `xdns,xhttp-reality`.
