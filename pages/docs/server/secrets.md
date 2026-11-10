# Secrets

`init` generates every secret except the upstreams: `upstream`, `upstream6`,
`upstream_wireguard` and `upstream_openvpn`. Set one with
`sudo morzer secret set <name>`, edit with `sudo morzer secret edit <name>`,
replace a generated one with `sudo morzer secret rotate <name>`.

| Name | Generated | |
| --- | --- | --- |
| `upstream` | no | the upstream proxy, `user:pass@host:port` or `host:port`, for `socks` and `http` |
| `upstream_wireguard` | no | a WireGuard exit's wg-quick client config, for `upstream_protocol=wireguard` ([tunnels](tunnel-upstream.md)) |
| `upstream_openvpn` | no | an OpenVPN exit's client config, keys inline, for `upstream_protocol=openvpn` |
| `upstream6` | no | the IPv6 proxy, same form; needed once `upstream6_protocol` is set |
| `upstream_backup` | no | the backup proxy, same form; needed once `upstream_backup_protocol` is set |
| `vless_clients` | yes | one `<uuid> [name]` line per device |
| `vless_seed` | yes | ML-KEM-768 seed the VLESS Encryption key pair derives from |
| `reality_key` | yes | REALITY private key (x25519) |
| `reality_short_id` | yes | REALITY short id clients present alongside the key |
| `xhttp_path` | yes | secret path Caddy routes to Xray's XHTTP inbound |
| `subscription_key` | yes | key the subscription URLs derive from |
| `kcp_seed` | yes | key [mKCP](mkcp.md)'s packets are encrypted under |

Rotating `vless_seed`, `reality_key`, `reality_short_id` or `xhttp_path`
changes every link, and `kcp_seed` the mKCP links: resend them, or let
subscriptions pick it up.
