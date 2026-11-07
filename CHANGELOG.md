# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- ...

### Changed

- ...

### Deprecated

- ...

### Removed

- ...

### Fixed

- The `canary-config` task's init command names the product, without which morzer 0.13.0 cannot install the canary from its registry reference.

### Security

- ...

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
