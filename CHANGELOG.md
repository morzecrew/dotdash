# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-11-08

### Changed

- The upstream proxy is one secret, `upstream`, holding `user:pass@host:port`, so changing proxy is one restart; `upstream_host`, `upstream_port`, `upstream_username` and `upstream_password` no longer work. Run `sudo morzer secret set upstream` before updating: an update without it is refused.

- This release is never applied unattended, and `morzer rollback` from it is refused, since 0.3.x could not start without the old settings; the pre-update backup is the way back.

- The IPv6 proxy is the `upstream6` secret in the same form, turned on by `upstream6_protocol` (`socks` or `http`, now `none` by default) instead of `upstream6_host`. With it on, set `upstream6` and `upstream6_protocol` before updating, or IPv6 goes back to the first proxy.

- Links are named after the device and transport, such as `phone [reality]`, `phone [xhttp]` and `phone [xhttp+reality]`, in place of `dotdash-phone`, `dotdash-xhttp-phone` and `dotdash-xhttp-reality-phone`. Apps show the new names once the links are added again, or at the next subscription refresh.

- With subscriptions on, `client-config` prints each device's subscription URL alone, so the output stays short; `--full` before the device's name (`-- --full phone`) adds its links and Xray config, as before. With subscriptions off it prints what it always did.

- The subscription service reports healthy only once every device's subscription is written: an apply or an update waits for it, and `doctor` names the service when that never happens.

## [0.3.0] - 2026-11-08

### Added

- Optional subscriptions (`subscription`): each device gets a URL on the cover site that serves its links, which `client-config` prints and the app refreshes by itself, so a revocation or a key rotation reaches devices without resending links. Rotating `subscription_key` moves every URL.

- An optional second proxy for IPv6 (`upstream6_host`, with its own credentials), for an upstream that leaves over IPv4 only: destinations with an IPv6 address, sites with both included, leave through it, and the rest through the first. Neither falls back to the other, and `doctor` names the one that fails.

### Changed

- The Xray config `client-config` prints checks all its entries at once every 30 seconds, where it checked one a minute in turn, so it leaves an entry that stops answering within about half a minute instead of up to several minutes. That is two small requests a minute per entry.

## [0.2.0] - 2026-11-08

### Added

- The `exit-check` task prints the IPv4 and IPv6 addresses the upstream leaves from, each with its network and country, and says whether IPv6 is unavailable or leaves from another network than IPv4. It changes nothing.

- Every apply and update, and every `doctor`, checks the release's invariants against what runs: traffic leaves through the upstream only, every inbound demands a client, and only the bundle's own ports are published, by unprivileged containers. An update that breaks one is rolled back; drift fails `doctor`.

- An optional third transport: XHTTP under REALITY instead of TLS, on a port of its own (`xhttp_reality_port`, 8443). The `xhttp-reality` profile turns it on, `xdns-xhttp-reality` with the DNS tunnel; `client-config` then prints a third link and outbound, and the first two as before.

- The canary's `measure` task fetches a URL through each transport N times and prints, as JSON, how many succeeded, timed out or failed, and the latency of those that succeeded.

- The canary's `xhttp-reality` profile checks XHTTP with REALITY beside REALITY, on the server's `xhttp_reality_port`.

- Both bundles carry signed build provenance, naming the commit and workflow run that built them. Check it with `gh attestation verify oci://ghcr.io/morzecrew/dotdash:<version> --owner morzecrew`, beside the signature morzer verifies.

- With several servers (`servers`), `canary-config` also prints how to point a canary at each of the others: they share the secrets, so only `server` and `address` change.

- The Xray config `client-config` prints answers the device's DNS, in an app's VPN or TUN mode, over DNS-over-HTTPS (`dns_resolver`) through the tunnel, with IPv4 addresses only: lookups no longer reach the local network's resolver or need the upstream to relay UDP. The README covers each app.

### Changed

- Both bundles need morzer 0.14.0 or later. `sudo morzer secret edit vless_clients` then opens the list as plain text, one client per line, and `init` needs no `--product`.

- When the way out fails, `doctor` says which layer did: the upstream proxy's address, its credentials, the destination behind it, or an exit that no longer matches `healthcheck_expect`. The health checks are now `cover-site` and `egress`.

- Xray's `log_level` defaults to `error`. At `warning` and below it names the destinations of failed connections, which a log should not keep; set it back for debugging.

- `client-config` prints one complete Xray config per device, for one server too: it uses whichever of REALITY and XHTTP answers fastest on any listed server, and the DNS tunnel only when none answers, instead of printing the tunnel's outbound alone.

### Fixed

- The cover site's error answers, such as 404 and 405, no longer name the server, and carry the site's headers like its pages do. A prober could tell them apart.

- The canary's `xhttp` profile applies. Its Compose file found the base file by a path relative to a directory morzer does not run Compose from, so the profile failed validation.

- A failed first apply, of dotdash or the canary, no longer leaves a directory where Xray's rendered configuration goes, which made every later apply fail to render it. A missing configuration file or Caddyfile now stops the container from starting instead.

### Security

- The upstream no longer learns which hostnames clients visit: this server resolves them over DNS-over-HTTPS sent through the upstream (`resolve=gateway`, the default) and hands it addresses only. A name resolving to a private address is blocked; `resolve=upstream` restores the old behaviour.

- Xray has no route out of the machine. It runs on internal networks only, and a small gate container forwards the public port to it and carries its traffic to the upstream, whose credentials only the gate holds. Whatever Xray's own config says, it cannot send traffic past the upstream.

- Caddy no longer writes the XHTTP path, a secret, to its log: it logs errors only, and never the request they concern, so no URI, header or client address either. An XHTTP session cut off mid-response used to log all three.

## [0.1.0] - 2026-11-07

### Added

- A morzer bundle for one Docker host, published as `ghcr.io/morzecrew/dotdash`: releases as `:X.Y.Z` and `:stable`, signed with the release key, and every change to main as `:main`, signed with the dev key. Requires morzer 0.13.0, Docker 28 and Compose 2.35, or later.

- REALITY on port 443: a client holding the key reaches Xray over VLESS with Vision, and anything else reaches a Caddy cover site with a Let's Encrypt certificate. `https_port` moves both to another host port.

- XHTTP over TLS behind one secret path of the cover site, which also works through a CDN that proxies HTTP/2 to the server.

- An optional DNS tunnel on UDP/53, VLESS over mKCP with XDNS, for networks where only DNS gets through. The `xdns` profile turns it on, at install or later; its zone is `t.<domain>` unless `xdns_domain` names another.

- Every inbound uses VLESS Encryption (ML-KEM-768). morzer generates every key, short id and path at install, so no secret is chosen by hand.

- All client traffic leaves through an upstream SOCKS5 or HTTP proxy you provide, optionally over TLS, with no direct fallback. UDP is relayed only through a SOCKS5 upstream that supports it (`upstream_udp`).

- Xray is healthy only while it fetches a URL through the upstream, and `doctor` fails while it cannot. With `healthcheck_expect`, a response that does not match, such as a changed exit IP, fails it too.

- An apply or update succeeds only once port 443 serves the cover site with a certificate a browser trusts.

- The `client-config` task prints each device's REALITY and XHTTP links, and the DNS tunnel's outbound when it is on. With `servers` naming servers that share the keys, it prints links for each and an Xray config that uses whichever answers fastest.

- One VLESS id per device in `vless_clients`: deleting a device's line revokes that device alone.

- The cover site serves your own static files from `site_dir` wherever they have the requested path, and otherwise a bundled page titled with the server's domain.

- `cert_issuer=internal` takes the certificate from Caddy's own CA instead of Let's Encrypt, for a machine the internet cannot reach.

- Unattended updates: the bundle declares that it keeps no database and is safe to roll back, which morzer requires before it installs a release on its own. Nightly backups include Caddy's certificates.

- The `canary-config` task prints the init command and secrets for a dotdash-canary machine acting as one of the clients.

- dotdash-canary, a second bundle released with dotdash as `ghcr.io/morzecrew/dotdash-canary`, for a machine inside a network you care about, such as a box at home. It connects to a dotdash server as an ordinary client and needs no open port.

- The canary's health check fetches `probe_url` through dotdash over REALITY, and with the `xhttp` profile also over XHTTP, in up to three tries. `doctor` fails when all three fail, so a notify target at its default level hears that the network lost its way out.

- Services run as a non-root user in read-only containers with every capability dropped. Xray's access log is always off.

- `scripts/bootstrap.sh` prepares a fresh Debian or Ubuntu server: Docker, sops, age and morzer, unattended security updates, and SSH with keys only once an authorized key exists.
