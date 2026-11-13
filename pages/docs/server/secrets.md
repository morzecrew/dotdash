# Secrets

`init` generates every secret except the ways out, `upstreams`. Set it with
`sudo morzer secret set <name>`, edit with `sudo morzer secret edit <name>`,
replace a generated one with `sudo morzer secret rotate <name>`.

| Name | Generated | |
| --- | --- | --- |
| `upstreams` | no | every way out, one per line, in order ([Upstreams](upstreams.md)); required |
| `vless_clients` | yes | one `<uuid> [name]` line per device |
| `vless_seed` | yes | ML-KEM-768 seed the VLESS Encryption key pair derives from |
| `acme_dns` | no | with `cert_issuer=acme-dns`, the acme-dns registration as JSON ([Certificates](certificates.md)) |
| `reality_key` | yes | REALITY private key (x25519) |
| `reality_short_id` | yes | REALITY short id clients present alongside the key |
| `xhttp_path` | yes | secret path Caddy routes to Xray's XHTTP inbound |
| `subscription_key` | yes | key the subscription URLs derive from |
| `kcp_seed` | yes | key [mKCP](mkcp.md)'s packets are encrypted under |

Rotating `vless_seed`, `reality_key`, `reality_short_id` or `xhttp_path`
changes every link, and `kcp_seed` the mKCP links: resend them, or let
subscriptions pick it up.
