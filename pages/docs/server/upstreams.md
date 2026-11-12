# Upstreams

Every connection leaves through the ways out the `upstreams` secret lists:
proxies, WireGuard exits and an OpenVPN exit, one per line, in order. A
change of provider, a backup or a second exit is one edit of that secret.

```sh
sudo morzer secret edit upstreams
```

```text
# <url> [name=<name>] [group=<group>]
socks5://alice:secret@203.0.113.7:1080            name=isp-a
https://bob:secret@proxy.example.net:443          name=isp-b
wireguard://<private key>@198.51.100.4:51820?publickey=<base64>&address=10.34.0.3/32 name=home
openvpn                                           name=vpn
```

| A line | Way out |
| --- | --- |
| `socks5://[user:pass@]host:port` | a SOCKS5 proxy |
| `socks5+tls://[user:pass@]host:port` | a SOCKS5 proxy over TLS |
| `http://[user:pass@]host:port` | an HTTP proxy |
| `https://[user:pass@]host:port` | an HTTP proxy over TLS |
| `wireguard://…` | a WireGuard exit, from its wg-quick file ([below](#wireguard)) |
| `openvpn` | the OpenVPN exit in `upstream_openvpn` ([below](#openvpn)) |

- After the scheme, a proxy is `user:pass@host:port`, or `host:port` with no
  login. The password may contain `:` and `@`, and is not percent-encoded. An
  IPv6 host goes in brackets.
- `name=` is optional, lowercase letters, digits and dashes. `doctor` and the
  gate's log name each line by it, and [`upstream_pin`](#order-and-modes)
  takes it.
- Blank lines and `#` lines are skipped.

Proxies with residential exits suit this best. With every line down, devices
get nothing, never the server's own address: [what leaks where](leaks.md).

## Order and modes

The gate probes every line through it, fetching `probe_url`, every 30
seconds, so every line sees that URL's host name; with `resolve=gateway`,
clients' destinations still reach them as addresses. `upstream_mode` decides how the lines that answer share the traffic:

| `upstream_mode` | |
| --- | --- |
| `failover` (default) | the first line while it answers, so the exit stays put; when it doesn't, the fastest of the rest, and back to the first once it answers again |
| `fastest` | whichever line answers fastest |
| `balance` | every line that answers, each connection to any of them |

- A failed line moves connections within about a minute. Connections open at
  that moment break, and apps reconnect.
- **The exit changes** with the line. Lines in one country keep geolocated
  sites behaving the same. Under `balance`, one site may see several exits in
  a session, which some sites answer with a captcha or a new login.
- `sudo morzer config set upstream_pin=isp-b` puts that line first whatever its
  place, the others behind it as the mode has them; `none` (the default)
  keeps the file's order.
- `doctor` passes while any line carries. `exit-check` shows the exit in use.
  If you [pin the exit IP](operations.md#pin-the-exit-ip), match every line's
  address to stay quiet when another carries, such as
  `'probe_expect=^(203\.0\.113\.7|198\.51\.100\.9)\s*$'`.

## IPv6

`ipv6` decides where IPv6 destinations go:

| `ipv6` | |
| --- | --- |
| `allow` (default) | through the lines like any other: right when every line has IPv6 |
| `separate` | through the lines marked `group=ipv6`, with `upstream_mode` applying to them alone, and never through the others |
| `block` | nowhere: names resolve to IPv4 only, so dual-stack sites still work over IPv4 |

A proxy carries IPv6 when its own host has it. A WireGuard exit does when its
`address` holds an IPv6 address and its exit routes IPv6, and an OpenVPN
exit when its server pushes IPv6. For IPv4-only proxies and a provider's
separate IPv6 one:

```text
socks5://alice:secret@203.0.113.7:1080        name=isp-a
socks5://alice:secret@[2001:db8::7]:1080      name=isp-a6 group=ipv6
```

```sh
sudo morzer config set ipv6=separate
sudo morzer task run exit-check --output
```

Destinations with an IPv6 address, dual-stack ones included, leave through
the IPv6 lines, the rest through the others, and neither falls back to the
other. A dual-stack WireGuard exit can serve both: `group=upstream,ipv6`.
`separate` needs `resolve=gateway` (the default); two providers show as
`MISMATCH` in `exit-check`, as expected.

## WireGuard

The `wireguard-line` task turns a wg-quick file, as a router or a provider
exports it, into its line:

```sh
sudo morzer task run wireguard-line --output --input conf=./wg0.conf
```

```text
wireguard://oIpc…%3D@vpn.example:51820?publickey=n9B5…%3D&address=10.34.0.3%2F32&allowedips=0.0.0.0%2F0%2C::%2F0&keepalive=25
```

- Add it to `upstreams`, with a `name=` if you like. The line holds the
  private key: treat it as the file.
- One `[Peer]` per line: a file with several needs splitting first.
- The gate runs Xray's own WireGuard, on its built-in network stack, so it
  needs no extra privilege. `DNS`, `PostUp` and the like are left out: this
  server resolves names itself and runs no scripts.
- A link an app shares works too: `wireguard://<key>@host:port?publickey=…&address=…`,
  with `mtu`, `presharedkey`, `keepalive` and `allowedips` (all of
  `0.0.0.0/0, ::/0` unless given).

## OpenVPN

One OpenVPN exit per server: it runs in a container of its own, which the
`openvpn` profile adds. Its config is an OpenVPN client config with its keys
inline (`<ca>`, `<cert>`, `<key>`, `<tls-crypt>`), and a provider's login goes
inline too:

```text
<auth-user-pass>
user
password
</auth-user-pass>
```

Set it, turn the profile on (the container starts while the other lines
still carry traffic), then add the `openvpn` line:

```sh
sudo morzer secret set upstream_openvpn < client.ovpn
sudo morzer config set installation.profile=openvpn    # with others, all of them: xdns,openvpn
sudo morzer secret edit upstreams                       # add: openvpn name=vpn
sudo morzer task run exit-check --output
```

- Before OpenVPN starts, its container's default route is replaced by routes
  to the servers in the config, so nothing leaves around the tunnel, even
  while it connects. Every `apply` and `doctor` checks that it has no default
  route around the tunnel.
- It runs as root with `NET_ADMIN` and `/dev/net/tun`, the one container here
  that does: OpenVPN takes nothing less.
- A new config in `upstream_openvpn` takes effect at once: setting it
  restarts OpenVPN. If OpenVPN exits, its container starts it again within a
  minute, and nothing leaves through it while it is down.
- The config can't run scripts, or send OpenVPN's log anywhere but
  `docker logs`. The servers' addresses are looked up when the container
  starts: a provider that moves its server is reached again after
  `sudo morzer restart vpn`.
- To drop it, remove the line, then the profile.

!!! warning "Exits must be outside the restricted network"
    WireGuard and OpenVPN are easy to detect and block. Between this server
    and an exit outside that doesn't matter; an exit inside the restricted
    network would be blocked, and would send the traffic back where it came
    from.

## UDP

`upstream_udp=true` carries devices' UDP, such as calls and QUIC, through the
lines. Every line must carry it then: a WireGuard or OpenVPN line, or a SOCKS5
proxy with UDP ASSOCIATE; an HTTP proxy drops it. Off, UDP is dropped here and
apps fall back to TCP.

## What doctor says

When nothing gets out, `doctor` asks the first lines directly and names each
by its `name=`: one that doesn't answer, one that refused the credentials in
its line, a WireGuard peer that didn't carry it, an OpenVPN tunnel that is
down. A line that answers when asked directly points at the gate instead.
