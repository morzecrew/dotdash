# Secrets

`init` generates every secret except `upstream`. Set one with
`sudo morzer secret set <name>`, edit with `sudo morzer secret edit <name>`,
replace a generated one with `sudo morzer secret rotate <name>`.

| Name | Generated | |
| --- | --- | --- |
| `upstream` | no | the upstream proxy, `user:pass@host:port` or `host:port` |
| `upstream6` | placeholder | the IPv6 proxy, same form; used once `upstream6_protocol` is set |
| `relays` | placeholder | one `<host> <site> <public key> <short id> <encryption>` line per [relay](../options/relay.md), as its `relay-entry` prints it |
| `vless_clients` | yes | one `<uuid> [name]` line per device |
| `vless_seed` | yes | ML-KEM-768 seed the VLESS Encryption key pair derives from |
| `reality_key` | yes | REALITY private key (x25519) |
| `reality_short_id` | yes | REALITY short id clients present alongside the key |
| `xhttp_path` | yes | secret path Caddy routes to Xray's XHTTP inbound |
| `subscription_key` | yes | key the subscription URLs derive from |

Rotating `vless_seed`, `reality_key`, `reality_short_id` or `xhttp_path`
changes every link: resend them, or let subscriptions pick it up.
