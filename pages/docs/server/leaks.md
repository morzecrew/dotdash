# What leaks where

- Traffic leaves only through the upstream. With the upstream down, clients
  get nothing, never this server's address. Xray has no route out; a gate
  container holds the upstream's credentials. Every apply, update and `doctor`
  checks this against what runs.
- The upstream sees destination addresses, ports and volume, not hostnames:
  this server resolves them over DoH (`dns_resolver`), through the upstream.
  SNI stays visible unless the client uses [ECH](cdn.md#ech-through-cloudflare).
  `resolve=upstream` hands the upstream the hostnames.
- On the device, only the app keeps traffic inside a dropped tunnel (TUN with
  a kill switch, or Android's "block connections without VPN"). A browser IP
  checker showing an IPv6 address that `exit-check` calls unavailable sees the
  device's own: route IPv6 into the tunnel or turn it off in the app.
- To keep IPv6 out altogether, set `ipv6=block` where it applies: on a
  [client](../client/reference.md) it is refused on the machine, on a
  [relay](../relay/reference.md) it ends there, and here no IPv6 destination
  leaves ([parameters](parameters.md)).
