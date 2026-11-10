# mKCP

A link over UDP on its own port (`kcp_port`, 8447), for a network that
blocks the TCP transports but lets UDP through. mKCP has no TLS underneath:
its packets are encrypted under the `kcp_seed` secret and start with a fake
header (`kcp_header`), so they look like neither KCP nor TLS. VLESS
Encryption still protects what they carry. Open the UDP port in the
provider's firewall, then:

```sh
sudo morzer config set installation.profile=mkcp   # with the DNS tunnel: xdns,mkcp
```

Each device gets a `phone [kcp]` link and an outbound in the Xray config.

- **Clients:** v2rayN and v2rayNG. mihomo has no mKCP: it treats the link as
  TCP, which never answers, and its health check skips it. sing-box apps
  can't use it either.
- **`kcp_header`:** `srtp` by default, a call's media packets. `dtls`,
  `utp`, `wechat`, `wireguard`, or `none` for bare encrypted packets. No
  header is known to pass everywhere: if one is blocked, try another, then
  let devices refresh their subscription or send them new links.
- **Bandwidth:** mKCP resends lost packets eagerly, so on a lossy line it
  uses more than TCP would. The Xray config picks it, as any other link,
  whenever it answers fastest.

Off: set the previous profile (`xdns`) or
`sudo morzer config unset installation.profile`, before any rollback to a
release without it.
