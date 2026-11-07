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
- One VLESS id per device: `vless_clients` holds one `<uuid> [name]` per line,
  so deleting a line revokes that device alone. `client-config` prints every
  client's settings, or one client's when given its name.
