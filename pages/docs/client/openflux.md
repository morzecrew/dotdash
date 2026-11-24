# OpenFlux fallback

For a client on a network that may, one day, let through only a handful of
services: a laptop on a phone's hotspot, a router on a mobile modem. When
every dotdash link fails its probe, the `openflux` profile hands the traffic
to an [OpenFlux](https://github.com/p1neappleXpress/OpenFlux) client. That
client reaches this device's OpenFlux exit on a dotdash server over a room or
call on such a service. When a link answers its probe again, the traffic
goes back to it.

It needs the server's [`openflux` profile](../server/openflux.md) with a
channel for this device. On the server:

```sh
sudo morzer task run openflux-link --output -- laptop
```

Then on the client:

```sh
sudo morzer secret edit openflux_link        # paste the line it printed
sudo morzer config set installation.profile=openflux
```

- **Speed:** 1-2 Mbit/s in the lab, enough for messages and pages. The link
  stays the way out until a dotdash link answers its probe again, at most
  a minute later.
- **One device, one channel.** The link is this device's own. A phone with
  the OpenFlux app on the same link pushes this client off its channel, and
  the other way round. Give each its own line on the server.
- **Not with `tun`.** The profile serves the proxy port and, shared,
  the LAN's apps set to it. The whole machine and the LAN gateway go
  without it for now.
- **Carriers that need no account only:** the client runs headless, with no
  way to answer a captcha a carrier may ask for.
