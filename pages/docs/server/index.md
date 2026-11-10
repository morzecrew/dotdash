# Server

The `dotdash` bundle (`ghcr.io/morzecrew/dotdash-server`) runs on one Docker host
outside the censored network. Devices connect to it on 443, and it sends
their traffic on through your upstream proxy, the only way out it has.

![Inside the server: gate holds the public ports and the upstream's credentials, Xray answers clients, Caddy serves the cover site](../assets/diagrams/server.light.svg#only-light)
![Inside the server: gate holds the public ports and the upstream's credentials, Xray answers clients, Caddy serves the cover site](../assets/diagrams/server.dark.svg#only-dark)

- **gate** is the only container with a route out. It forwards the public
  ports in to Xray and carries Xray's traffic out to the upstream proxy, whose
  credentials only it holds.
- **Xray** answers on 443 with REALITY. A dotdash device goes on through the
  upstream; anything else, a censor's probe or a browser, is handed to Caddy,
  so 443 looks like an ordinary HTTPS site.
- **Caddy** serves that site with a trusted certificate, each device's
  subscription URL, and XHTTP on a secret path, which is what lets XHTTP
  pass through a CDN.

The upstream is a SOCKS5 or HTTP proxy you choose, typically one with a
residential exit. With it down, devices get nothing, never the server's own
address: [what leaks where](leaks.md).

## Steps

1. [Install](install.md) the server.
2. [Connect devices](devices.md): links, an Xray config, or subscriptions.
3. Optional:
   - [your own cover site](cover-site.md);
   - a [DNS tunnel](dns-tunnel.md) for networks that pass little but DNS;
   - [XHTTP with REALITY](xhttp-reality.md) on another port;
   - a [second proxy for IPv6](ipv6-upstream.md);
   - a [WireGuard or OpenVPN exit](tunnel-upstream.md) instead of a proxy;
   - a [CDN](cdn.md) in front of XHTTP: a domestic one for allowlists, or a
     foreign one against IP blocking;
   - [several servers](several-servers.md) sharing one set of keys.
4. [Operations](operations.md): updates, alerts, backups, and
   [moving to a new server](move-server.md).
