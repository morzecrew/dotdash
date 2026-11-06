# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- morzer bundle `dotdash`: Caddy behind Cloudflare (Origin CA certificate,
  zone-level Authenticated Origin Pulls) in front of Xray's VLESS + XHTTP
  inbound, a VLESS + XDNS DNS tunnel on UDP/53, and all egress through an
  ISP/residential SOCKS5 or HTTP proxy with no direct fallback.
- Health: Xray is healthy only while a URL fetched through the upstream proxy
  answers; the smoke test checks that the origin refuses TLS without
  Cloudflare's client certificate.
- `client-config` task printing the XHTTP share link and the XDNS outbound.
- VLESS Encryption keys derive from a morzer-generated seed (`vless_seed`), so
  installing needs no key generation by hand.
- `scripts/cf-aop-cert.sh` for the Authenticated Origin Pulls CA and client
  certificate.
