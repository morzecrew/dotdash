# Parameters

| Name | Default | |
| --- | --- | --- |
| `upstream_protocol` | `socks` | `socks` or `http`, the proxy in `upstream`; `wireguard` or `openvpn`, a [tunnel](tunnel-upstream.md) from `upstream_wireguard` or `upstream_openvpn` |
| `upstream_tls` | `false` | TLS to the upstream |
| `upstream_udp` | `false` | relay UDP via a SOCKS5 upstream with UDP ASSOCIATE; otherwise dropped. A tunnel always carries UDP |
| `upstream6_protocol` | `none` | `socks` or `http` turns on the IPv6 proxy, the `upstream6` secret |
| `upstream6_tls` | `false` | TLS to the IPv6 proxy |
| `upstream_backup_protocol` | `none` | `socks` or `http` turns on the [backup proxy](backup-upstream.md), the `upstream_backup` secret |
| `upstream_backup_tls` | `false` | TLS to the backup proxy |
| `https_port` | `443` | host port for REALITY and the site |
| `xdns_domain` | `t` | tunnel zone (`xdns`); a name with no dot is under the domain |
| `xdns_bind` | `0.0.0.0` | host address for UDP/53 |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies get lost |
| `xhttp_reality_port` | `8443` | port for XHTTP with REALITY; not `https_port` or 80 |
| `kcp_port` | `8447` | UDP port for [mKCP](mkcp.md); not 53 with the DNS tunnel |
| `kcp_header` | `dtls` | what mKCP's packets start with: `dtls`, `srtp`, `utp`, `wechat`, `wireguard` or `none` |
| `log_level` | `error` | Xray error log; `warning` and below name failed destinations |
| `healthcheck_url` | `https://www.gstatic.com/generate_204` | fetched through the upstream |
| `healthcheck_expect` | `.*` | regex the response must match, such as the exit IP |
| `healthcheck6_url` | `http://api6.ipify.org` | IPv6-only URL fetched through the IPv6 proxy |
| `resolve` | `gateway` | `gateway`: this server resolves over `dns_resolver`; `upstream`: the upstream sees hostnames |
| `ipv6` | `allow` | `block`: no IPv6 destination leaves; names resolve to IPv4 only and the upstream is dialled over IPv4, so dual-stack sites still work (with `resolve=upstream`, the upstream resolves names itself). Not with `upstream6_protocol` |
| `dns_resolver` | `https://1.1.1.1/dns-query` | DoH server for `resolve=gateway` and device DNS; `https://` only |
| `subscription` | `false` | a subscription URL per device |
| `cert_issuer` | `acme` | `acme` (Let's Encrypt) or `internal` (offline machines) |
| `site_dir` | `/srv/dotdash` | your own cover site |
| `servers` | `self` | servers sharing these keys, comma-separated |
| `cdn_hosts` | `none` | the names of domestic [CDNs](cdn.md#a-domestic-cdn-for-allowlists) in front of this server, comma-separated; a link through each |
| `relays` | a comment | one `<host> <site> <public key> <short id> <encryption>` line per [relay](../relay/install.md), as its `relay-entry` prints it, with `own-site <path>`, `kcp=<port>,<header>,<seed>` and `cdn=<name>[,<name>]` after it where the relay has them |
| `pools` | a comment | one `<pool> <member>...` line per [pool](devices.md#pools), the members device names, relay hosts and CDN hosts |

Set one with `sudo morzer config set <name>=<value>`, unset it with
`sudo morzer config unset <name>`, edit `relays` or `pools` with
`sudo morzer config edit <name>`. Profiles (`installation.profile`): `xdns`,
`xhttp-reality`, `mkcp`, `openvpn` (for an [OpenVPN upstream](tunnel-upstream.md)),
combined with commas, such as `xdns,xhttp-reality`.
