# Parameters

| Name | Default | |
| --- | --- | --- |
| `upstream_protocol` | `socks` | `socks` or `http`; the proxy is the `upstream` secret |
| `upstream_tls` | `false` | TLS to the upstream |
| `upstream_udp` | `false` | relay UDP via a SOCKS5 upstream with UDP ASSOCIATE; otherwise dropped |
| `upstream6_protocol` | `none` | `socks` or `http` turns on the IPv6 proxy, the `upstream6` secret |
| `upstream6_tls` | `false` | TLS to the IPv6 proxy |
| `https_port` | `443` | host port for REALITY and the site |
| `xdns_domain` | `t` | tunnel zone (`xdns`); a name with no dot is under the domain |
| `xdns_bind` | `0.0.0.0` | host address for UDP/53 |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies get lost |
| `xhttp_reality_port` | `8443` | port for XHTTP with REALITY; not `https_port` or 80 |
| `log_level` | `error` | Xray error log; `warning` and below name failed destinations |
| `healthcheck_url` | `https://www.gstatic.com/generate_204` | fetched through the upstream |
| `healthcheck_expect` | `.*` | regex the response must match, such as the exit IP |
| `healthcheck6_url` | `http://api6.ipify.org` | IPv6-only URL fetched through the IPv6 proxy |
| `resolve` | `gateway` | `gateway`: this server resolves over `dns_resolver`; `upstream`: the upstream sees hostnames |
| `dns_resolver` | `https://1.1.1.1/dns-query` | DoH server for `resolve=gateway` and device DNS; `https://` only |
| `subscription` | `false` | a subscription URL per device |
| `cert_issuer` | `acme` | `acme` (Let's Encrypt) or `internal` (offline machines) |
| `site_dir` | `/srv/dotdash` | your own cover site |
| `servers` | `self` | servers sharing these keys, comma-separated |
| `relays` | a comment | one `<host> <site> <public key> <short id> <encryption>` line per [relay](../relay/install.md), as its `relay-entry` prints it |

Set one with `sudo morzer config set <name>=<value>`, unset it with
`sudo morzer config unset <name>`, edit `relays` with
`sudo morzer config edit relays`. Profiles (`installation.profile`): `xdns`,
`xhttp-reality`, or both as `xdns,xhttp-reality`; `xdns-xhttp-reality` does the
same and goes in the next release.
