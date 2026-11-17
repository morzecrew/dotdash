# Hysteria2

A link over QUIC on a UDP port of its own (`hysteria2_port`, 443), for a
network that lets UDP through. Hysteria2 runs in the server's own Xray, so
it needs no other software. To the network it looks like an HTTP/3
connection to your domain, under the site's own certificate: a client that
brings no login gets the cover site over HTTP/3. Open the UDP port in the
provider's firewall, then:

```sh
sudo morzer config set installation.profile=hysteria2   # with the DNS tunnel: xdns,hysteria2
```

Each device gets a `phone [hy2]` link and an outbound in the Xray config. Its
login is the device's own UUID, so revoking a device in `vless_clients`
revokes it here too.

- **Clients:** Happ, v2rayN, v2rayNG, Hiddify, Streisand, mihomo and the
  sing-box apps read `hysteria2://` links. dotdash-client takes it from its
  subscription like any other outbound.
- **One address, two families.** Some networks block a server's whole
  address for minutes after they see UDP to it from abroad. That would take
  its TCP links with it, so give Hysteria2 a server, or an address, of its own
  where you can, and measure it on a canary before relying on it.
- **`hysteria2_up`:** `0` by default: Hysteria2 runs BBR, which backs off on
  loss as TCP does. Set it to the Mbit/s each device may get, and a device
  that asks for a rate gets Brutal: a steady send at that rate whatever is
  lost, which holds up on lossy mobile links. Never set it above what the
  server's uplink can give each device, or it floods the line.
- **The certificate** is Caddy's: Xray reads it from Caddy's data and reloads
  it hourly. Under this profile Caddy starts first, and on a fresh install
  Xray retries until Caddy has taken the certificate, which takes seconds
  with Let's Encrypt.

Off: set the previous profile (`xdns`) or
`sudo morzer config unset installation.profile`, before any rollback to a
release without it.
