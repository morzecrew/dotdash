# dotdash

First release.

- Caddy as the only TCP entrypoint, locked to Cloudflare by an Origin CA
  certificate and zone-level Authenticated Origin Pulls; a static cover site on
  every path but one.
- Xray with VLESS + XHTTP behind Caddy and VLESS + mKCP + XDNS on UDP/53, both
  with VLESS Encryption (ML-KEM-768).
- All egress through an ISP/residential SOCKS5 or HTTP proxy, with no direct
  fallback. Xray's healthcheck fetches a URL through it.
- `morzer task run client-config --output` prints the client settings.
