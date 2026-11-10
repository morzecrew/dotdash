# WireGuard or OpenVPN upstream

Instead of a SOCKS5 or HTTP proxy, the upstream can be a WireGuard or an
OpenVPN exit: your own router at home abroad, say, or a VPN provider. The
client config the exit gives you goes in a secret of its own, and all traffic
leaves through that tunnel. The proxy in `upstream` stays where it is, so
the proxy carries traffic until the moment the tunnel takes over, and going
back needs nothing set again.

A tunnel carries UDP and, if the exit has it, IPv6, so it needs neither
`upstream_udp` nor the [second proxy for IPv6](ipv6-upstream.md). It resolves
no names, so it needs `resolve=gateway`, the default.

!!! warning "The exit must be outside the censored network"
    Censors detect and block WireGuard and OpenVPN. Between this server and an
    exit abroad that doesn't matter; an exit inside the country would be
    blocked, and would send the traffic back where it came from.

## WireGuard

The config is a wg-quick file, as a router or a provider exports it:

```ini
[Interface]
PrivateKey = <base64>
Address = 10.34.0.3/32, fd30:2::3/128
DNS = 1.1.1.1

[Peer]
PublicKey = <base64>
Endpoint = vpn.example:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
```

```sh
sudo morzer secret set upstream_wireguard < wg.conf
sudo morzer config set upstream_protocol=wireguard
sudo morzer task run exit-check --output
```

- The gate runs Xray's own WireGuard, on its built-in network stack, so it
  needs no extra privilege.
- `DNS`, `PostUp` and the like are ignored: this server resolves names
  itself and runs no scripts.
- `apply` succeeds once a fetch gets out through the peer. With the peer down,
  nothing gets out, and `doctor` names the WireGuard peer.

## OpenVPN

The config is an OpenVPN client config with its keys inline (`<ca>`,
`<cert>`, `<key>`, `<tls-crypt>`). A provider's login goes inline too:

```text
<auth-user-pass>
user
password
</auth-user-pass>
```

OpenVPN runs in a container of its own, which the `openvpn` profile adds.
Turn the profile on first: the container starts while the proxy still
carries traffic, and the second step moves the traffic to it.

```sh
sudo morzer secret set upstream_openvpn < client.ovpn
sudo morzer config set installation.profile=openvpn    # with others, all of them: xdns,openvpn
sudo morzer config set upstream_protocol=openvpn
sudo morzer task run exit-check --output
```

- Before OpenVPN starts, its container's default route is replaced by routes
  to the servers in the config, so nothing leaves around the tunnel, even
  while it connects. Every `apply` and `doctor` checks that it has no default
  route around the tunnel.
- It runs as root with `NET_ADMIN` and `/dev/net/tun`, the one container here
  that does: OpenVPN takes nothing less.
- A new config in `upstream_openvpn` while OpenVPN runs takes effect after
  `sudo morzer restart vpn`.
- The config can't run scripts, or send OpenVPN's log anywhere but
  `docker logs`.
- The servers' addresses are looked up when the container starts. A provider
  that moves its server is reached again after `sudo morzer restart vpn`.

## Back to a proxy

The proxy in `upstream` is still there:

```sh
sudo morzer config set upstream_protocol=socks           # or http
sudo morzer config unset installation.profile           # from OpenVPN, then: or the profiles you had, such as xdns
```
