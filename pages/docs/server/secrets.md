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
| `reality_key_second` | no | with `reality_second_key`, a second REALITY private key ([Rotating the REALITY key](#rotating-the-reality-key)) |
| `reality_short_id_second` | no | with `reality_second_key`, the short id that goes with it |

Rotating `vless_seed`, `reality_key`, `reality_short_id` or `xhttp_path`
changes every link, and `kcp_seed` the mKCP links: resend them, or let
subscriptions pick it up.

## Rotating the REALITY key

`secret rotate reality_key` cuts off every device until it has the new
links. With `reality_second_key`, the server accepts a second key beside
`reality_key`, so devices holding either get in, and the key can change with
no one cut off. A prober meets the site through both, as before.

1. **The next key, second.** Make a key pair and a short id, and set them as
   the second key. Devices keep working, and links still carry the current
   key. Put a [canary](../canary/index.md) on the next key
   (`dotdash_public_key` and `dotdash_short_id`) and check that it gets
   through:

    ```sh
    sudo docker run --rm ghcr.io/morzecrew/xray:26.11.9 x25519    # PrivateKey, and Password, its public half
    openssl rand -hex 8 | sudo morzer secret set reality_short_id_second
    sudo morzer secret set reality_key_second                      # paste the PrivateKey
    sudo morzer config set reality_second_key=true
    ```

2. **Swap.** Set the next key and short id as `reality_key` and
   `reality_short_id`, and the old ones as the second key. Links and
   subscriptions now carry the new key, and devices still on the old one
   keep getting in.

3. **Retire the old key.** Once subscriptions have refreshed and you've
   resent links (devices fetch a subscription every hour by default), turn
   the second key off:

    ```sh
    sudo morzer config set reality_second_key=false
    ```

With [relays](../relay/index.md) or [several servers](several-servers.md),
set the same keys on each server, and move relays to the new key
(`dotdash_public_key`, `dotdash_short_id`) between steps 2 and 3.

