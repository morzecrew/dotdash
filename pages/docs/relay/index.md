# Relay

Some networks let only a set list of addresses through, for a region or for
mobile data. A device there can't reach a dotdash server outside at all. The
`dotdash-relay` bundle (`ghcr.io/morzecrew/dotdash-relay`) runs on a machine
inside that network, whose address does get through, and carries devices on
to the server.

![A phone connects to the relay inside the restricted network on 443 under the name of a site next to it; the relay carries it on to whichever dotdash server answers fastest](../assets/diagrams/relay.light.svg#only-light)
![A phone connects to the relay inside the restricted network on 443 under the name of a site next to it; the relay carries it on to whichever dotdash server answers fastest](../assets/diagrams/relay.dark.svg#only-dark)

## How it works

- Devices connect to the relay on 443 with REALITY, under the name of a
  site: best, the relay's own, a domain pointing at it and a site it serves
  (the `own-site` profile); or a real site next to it, borrowed (its `site`
  parameter). To the network, the connection looks like one to that site.
- Anyone probing the relay's 443 without its keys meets that site: its own,
  with a certificate for its name, or the borrowed site's real handshake.
- The relay has keys of its own, and its own copy of the devices allowed in.
  A device uses the same id as on the server, with a separate link per relay,
  `phone [relay <host>]`.
- The relay goes on to the server as one client of its own, a line in the
  server's `vless_clients`. With [several servers](../server/several-servers.md),
  it uses whichever answers fastest, so a ban on one address doesn't cut it off.
- Nothing leaves the relay except to dotdash: traffic still exits through
  the server's upstream proxy.

It can also help where home and mobile lines slow down TLS to faraway
hosting: devices then reach only a nearby address, and the relay's own
link to the server runs from its hosting network, which the slowdown may not
reach.

## Before you start

- **The relay's address must get through.** Whether one does depends on the
  network, the provider and the day:
  - host it in a network whose addresses get through, such as a large
    cloud or hosting provider inside the restricted network. A public list
    of such subnets is a first filter only, because such lists go stale;
  - test it from each network that matters, on mobile data with Wi-Fi off,
    before relying on it;
  - run at least two relays, in different networks, so one blocked
    address costs devices nothing. A spare left installed is [moved into
    place](operations.md#move-a-relay) with a DNS change;
  - expect the subnets that get through to shrink, and keep a
    [local CDN](../server/cdn.md) as another way in.
- On those networks only 443 and TCP get through: the
  [DNS tunnel](../server/dns-tunnel.md) is no use there.
- **Devices need the relay links before restrictions start.** An app can't
  refresh a subscription from the server's site while only some addresses get
  through, though it can through a relay with a site of its own. See
  [Keep more than one way in](../ways-in.md).
- The machine needs Docker, sops, age and morzer
  ([`bootstrap.sh`](../index.md#what-every-machine-needs)), and port 443 free.
- The official sing-box apps, Karing and NekoBox can't connect to dotdash,
  relay or not: they lack VLESS Encryption and the key share Xray's REALITY
  requires.

Next: [set one up](install.md).
