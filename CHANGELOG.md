# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- morzer bundle `dotdash`: Xray's VLESS + REALITY (Vision) inbound on 443 in
  front of a Caddy cover site with a Let's Encrypt certificate, VLESS + XHTTP
  behind one secret path of that site for a CDN in front, and an optional
  VLESS + XDNS DNS tunnel on UDP/53 (`xdns` profile, zone `t.<domain>` by
  default). All egress goes through
  an ISP/residential SOCKS5 or HTTP proxy, optionally over TLS, with no direct
  fallback.
- Health: Xray is healthy only while a URL fetched through the upstream proxy
  answers; the smoke test checks that port 443 serves the site with a trusted
  certificate.
- `client-config` task printing the REALITY and XHTTP share links and, under
  the `xdns` profile, the XDNS outbound.
- morzer generates every key: the REALITY key and short id, and the VLESS
  Encryption key pair, which derives from one seed (`vless_seed`).
- `cert_issuer`: Let's Encrypt (`acme`, the default) or Caddy's own CA
  (`internal`) for a machine the internet cannot reach.
- CI through bundle-ci: every pull request and push builds, signs and
  smoke-tests the bundle in a rig with a stand-in upstream proxy; a push to
  `main` publishes `ghcr.io/morzecrew/dotdash:main`, a `vX.Y.Z` tag `:X.Y.Z`
  and `:stable`.
- One VLESS id per device: `vless_clients` holds one `<uuid> [name]` per line,
  so deleting a line revokes that device alone. `client-config` prints every
  client's settings, or one client's when given its name.
- Unattended updates: the manifest declares `database_schema_produces`, which
  morzer's `update.auto_apply` requires before it installs a release on its
  own. The README covers turning them on, offsite backups and alerts.
- `site_dir` (default `/srv/dotdash`): Caddy serves your own cover site from
  it wherever it has the requested file. The bundled page is now titled with
  the domain, so no two servers serve the same page.
- `servers`: several servers sharing the same keys. `client-config` prints
  links for each and an Xray config that uses whichever answers fastest.
- README: QR codes for the share links.
- `doctor` fails, so a notify target at its default level hears it, when Xray
  cannot reach the internet through the upstream: a fatal preflight check
  probes it live. An unhealthy container alone only warns there.
- `healthcheck_expect`: a regular expression the healthcheck response must
  match. With `healthcheck_url` at an IP-echo service, a changed exit IP makes
  Xray unhealthy and fails `doctor`.
- The canary, a second bundle in `canary/` published as
  `ghcr.io/morzecrew/dotdash-canary` (releases tagged `canary-vX.Y.Z`): a
  dotdash client on a machine inside a network, whose `doctor` fails when it
  cannot fetch `probe_url` through dotdash. The `canary-config` task prints its
  init command and secrets.
- README: moving to a new server from the recovery key and a backup, with the
  client links unchanged.
- `scripts/bootstrap.sh` prepares a fresh Debian or Ubuntu server: Docker and
  Compose, sops, age, morzer, security updates, and SSH with keys only.
