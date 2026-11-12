# Parameters

| Name | Default | |
| --- | --- | --- |
| `upstream_mode` | `failover` | how the [upstreams](upstreams.md#order-and-modes) lines share the traffic: `failover` (the first that answers), `fastest` or `balance` |
| `upstream_pin` | `none` | the `name=` of the line that goes first; under `ipv6=separate`, a second name pins the IPv6 lines |
| `upstream_udp` | `false` | carry UDP through the upstreams, every one of which must carry it (WireGuard, OpenVPN, SOCKS5 with UDP ASSOCIATE); otherwise dropped |
| `https_port` | `443` | host port for REALITY and the site |
| `xdns_domain` | `t` | tunnel zone (`xdns`); a name with no dot is under the domain |
| `xdns_bind` | `0.0.0.0` | host address for UDP/53 |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies get lost |
| `xhttp_reality_port` | `8443` | port for XHTTP with REALITY; not `https_port` or 80 |
| `kcp_port` | `8447` | UDP port for [mKCP](mkcp.md); not 53 with the DNS tunnel |
| `kcp_header` | `dtls` | what mKCP's packets start with: `dtls`, `srtp`, `utp`, `wechat`, `wireguard` or `none` |
| `log_level` | `error` | Xray error log; `warning` and below name failed destinations |
| `probe_url` | `https://www.gstatic.com/generate_204` | fetched through the upstreams, and through each line every 30 s |
| `probe_expect` | `.*` | regex the response must match, such as the exit IP |
| `probe6_url` | `http://api6.ipify.org` | IPv6-only URL fetched through the IPv6 lines, with `ipv6=separate` |
| `resolve` | `gateway` | `gateway`: this server resolves over `dns_resolver`; `upstream`: the upstream proxies see hostnames (no WireGuard or OpenVPN line then) |
| `ipv6` | `allow` | `allow`: IPv6 leaves like the rest; `separate`: through the [`group=ipv6` lines](upstreams.md#ipv6) alone; `block`: no IPv6 destination leaves, names resolve to IPv4 only, so dual-stack sites still work (with `resolve=upstream`, the upstream resolves names itself) |
| `dns_resolver` | `https://1.1.1.1/dns-query` | DoH server for `resolve=gateway` and device DNS; `https://` only |
| `subscription` | `false` | a subscription URL per device |
| `cert_issuer` | `acme` | `acme` (Let's Encrypt) or `internal` (offline machines) |
| `site_dir` | `/srv/dotdash` | your own cover site |
| `site_upstream` | `none` | your own [app](cover-site.md#an-app-instead-of-pages) behind the cover site, such as `http://cover-app:8080` on the network `dotdash_edge` |
| `servers` | `self` | servers sharing these keys, comma-separated |
| `cdn_hosts` | `none` | the names of local [CDNs](cdn.md#a-local-cdn-for-restricted-networks) in front of this server, comma-separated; a link through each |
| `relays` | a comment | one `<host> <site> <public key> <short id> <encryption>` line per [relay](../relay/install.md), as its `relay-entry` prints it, with `own-site <path>`, `kcp=<port>,<header>,<seed>` and `cdn=<name>[,<name>]` after it where the relay has them |
| `pools` | a comment | one `<pool> <member>...` line per [pool](devices.md#pools), the members device names, relay hosts and CDN hosts |

Set one with `sudo morzer config set <name>=<value>`, unset it with
`sudo morzer config unset <name>`, edit `relays` or `pools` with
`sudo morzer config edit <name>`. Profiles (`installation.profile`): `xdns`,
`xhttp-reality`, `mkcp`, `openvpn` (for an [OpenVPN line](upstreams.md#openvpn)),
combined with commas, such as `xdns,xhttp-reality`.
