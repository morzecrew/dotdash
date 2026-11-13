# Relay reference

## Parameters

Set one with `sudo morzer config set <name>=<value>`.

| Name | Default | |
| --- | --- | --- |
| `site` | `none` | without the `own-site` profile, a site next to the relay, in its own network, on TLS 1.3 and HTTP/2: devices send its name, and probes get its handshake |
| `cover` | `pages` | with `own-site`, what the site serves past your own files in `/srv/dotdash-relay`: `pages`, the bundled page, or your [app](../server/cover-site.md#an-app-instead-of-pages)'s URL, such as `http://cover-app:8080` on the network `dotdash-relay_default` or `http://host.docker.internal:8080` |
| `cert_issuer` | `acme` | with `own-site`, `acme` (Let's Encrypt, over port 80), `acme-dns` (a [wildcard](../server/certificates.md) over a DNS-01 check handed to acme-dns, the `acme_dns` secret) or `internal` (Caddy's own CA, for a machine the internet can't reach) |
| `entry_host` | `none` | the address devices reach the relay at, its IP without a domain, for `relay-entry` with no address and for `facts`; `none` under `own-site` is the relay's domain |
| `cdn_hosts` | `none` | with `own-site`, the names devices use for [local CDNs](../server/cdn.md#in-front-of-a-relay) in front of the relay, comma-separated; `relay-entry` adds them to the relay's line |
| `dotdash_servers` | none, given at `init` | the dotdash servers sharing one set of keys, comma-separated domains; the relay uses whichever answers fastest |
| `dotdash_port` | `443` | the servers' `https_port` |
| `dotdash_public_key` | none, given at `init` | the servers' REALITY public key, the `pbk` of their links |
| `dotdash_address` | `none` | where to connect when `dotdash_servers` names one server, such as its IP; `none` reaches each server by its name |
| `probe_url` | `https://www.gstatic.com/generate_204` | what the health check fetches through dotdash; any 2xx is healthy |
| `ipv6` | `allow` | `block`: IPv6 destinations end at the relay and never reach a server; names go on |
| `kcp_port` | `8447` | with `mkcp`, the UDP port devices reach the relay's mKCP on |
| `kcp_header` | `dtls` | with `mkcp`, what its packets start with, as the server's [`kcp_header`](../server/mkcp.md) |

## Profiles

`installation.profile=own-site`: the relay serves a site of its own under its
domain (`--domain` at `init`, or `installation.domains`), and REALITY hands it
every connection without the relay's keys. It publishes port 80 too, for the
certificate. The site also serves devices their subscriptions, fetched from
the servers through the relay's tunnel, and XHTTP on the secret path
`xhttp_path`, which `init` generates. With `cdn_hosts` set, `relay-entry`
ends the relay's line with `cdn=<name>,...`, and the server gives each device
a `[relay <host> cdn <name>]` link through each
([CDN in front of a relay](../server/cdn.md#in-front-of-a-relay)). See
[Set up a relay](install.md#1-pick-the-site).

`installation.profile=mkcp` (with a site of its own: `own-site,mkcp`): the
relay serves [mKCP](../server/mkcp.md) on UDP `kcp_port` too, under its own
`kcp_seed`, and carries it on to the servers like REALITY. `relay-entry` then
ends the relay's line with `kcp=<port>,<header>,<seed>`, from which the server
gives each device a `[relay <host> kcp]` link. Open the UDP port in the
provider's firewall, and replace the relay's line on the server after turning
it on.

## Secrets

`init` generates the relay's own keys; the rest come from the server's
`relay-config`.

| Name | Generated | |
| --- | --- | --- |
| `vless_clients` | no | the devices the relay lets in, one `<uuid> [name]` per line |
| `dotdash_id` | no | the id the relay uses on the server, its line in the server's `vless_clients` |
| `dotdash_encryption` | no | the `encryption=` value of the server's links |
| `dotdash_short_id` | no | the `sid=` value of the server's REALITY links |
| `vless_seed` | yes | the seed the relay's VLESS Encryption key pair derives from |
| `reality_key` | yes | the relay's REALITY private key |
| `reality_short_id` | yes | the relay's REALITY short id |
| `kcp_seed` | yes | the key the relay's mKCP packets are encrypted under, with `mkcp` |

## Tasks

| Task | |
| --- | --- |
| `relay-entry --output -- <address>` | the relay's line for the server's `relays`, and how a canary checks the relay; with no address, at `entry_host` |
| `facts --output` | the same line as JSON, which the relay publishes to an authority it [follows](../server/operations.md#managed-from-elsewhere) |
