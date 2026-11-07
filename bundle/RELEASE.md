# dotdash

First release.

- Xray's VLESS + REALITY (Vision) inbound on 443. A client with the key gets
  Xray; anything else reaches a Caddy cover site with a Let's Encrypt
  certificate.
- VLESS + XHTTP behind one secret path of that site, for a CDN in front, and
  an optional VLESS + mKCP + XDNS tunnel on UDP/53 (`xdns` profile). Every
  inbound uses VLESS Encryption (ML-KEM-768).
- All egress through an ISP/residential SOCKS5 or HTTP proxy, optionally over
  TLS, with no direct fallback. Xray's healthcheck fetches a URL through it.
- `morzer task run client-config --output` prints the client settings.
