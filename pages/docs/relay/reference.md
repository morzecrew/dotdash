# Relay reference

## Parameters

Set one with `sudo morzer config set <name>=<value>`.

| Name | Default | |
| --- | --- | --- |
| `site` | `none` | without the `own-site` profile, a site next to the relay, in its own network, on TLS 1.3 and HTTP/2: devices send its name, and probes get its handshake |
| `site_dir` | `/srv/dotdash-relay` | with `own-site`, your own pages, served in place of the bundled one; readable by uid 65532 |
| `cert_issuer` | `acme` | with `own-site`, `acme` (Let's Encrypt, over port 80) or `internal` (Caddy's own CA, for a machine the internet can't reach) |
| `dotdash_servers` | none, given at `init` | the dotdash servers sharing one set of keys, comma-separated domains; the relay uses whichever answers fastest |
| `dotdash_port` | `443` | the servers' `https_port` |
| `dotdash_public_key` | none, given at `init` | the servers' REALITY public key, the `pbk` of their links |
| `dotdash_address` | `none` | where to connect when `dotdash_servers` names one server, such as its IP; `none` reaches each server by its name |
| `probe_url` | `https://www.gstatic.com/generate_204` | what the health check fetches through dotdash; any 2xx is healthy |
| `dotdash_server` | `none` | deprecated: the one server, read only while `dotdash_servers` is unset |

## Profiles

`installation.profile=own-site`: the relay serves a site of its own under its
domain (`--domain` at `init`, or `installation.domains`), and REALITY hands it
every connection without the relay's keys. It publishes port 80 too, for the
certificate. The site also serves devices their subscriptions, fetched from
the servers through the relay's tunnel, and XHTTP on the secret path
`xhttp_path`, which `init` generates. See
[Set up a relay](install.md#1-pick-the-site).

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

## Tasks

| Task | |
| --- | --- |
| `relay-entry --output -- <address>` | the relay's line for the server's `relays`, and how a canary checks the relay |
