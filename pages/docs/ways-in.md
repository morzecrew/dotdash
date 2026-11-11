# Keep more than one way in

Some networks let through only a set list of addresses, for a region or for
mobile data, and your servers need not be on it. The server then stops
answering devices there, while a relay inside that network and a local CDN
may still answer. Set them up and hand everything out **before** restrictions
start, while devices still reach the server.

## Before

1. **A relay with a site of its own** ([set one up](relay/install.md)), in a
   network that stays reachable. Give `relay-entry` the relay's domain
   rather than its IP: links and subscription URLs then name the domain, and
   moving the relay to a new address only takes a DNS change.
2. **A canary on the kind of line devices use** ([canary](canary/index.md)),
   checking the relay. It alerts you when a way in stops working for devices
   like yours.
3. **A local CDN**, as one more way in ([CDN](server/cdn.md)). Expect the
   account to be closed one day.
4. **Every device** gets its links again once the relay and the CDN are in.
   With subscriptions on, give a device inside the restricted network its
   subscription URL through the relay (`through the relay …` in
   `client-config`), not the server's. Its app then keeps refreshing its links
   while restrictions last.
5. **Test** on a phone on the network you care about, using mobile data with
   Wi-Fi off and the relay link alone.

## During

- An app that can't fetch its subscription keeps the links it already has.
  With the URL through the relay, it keeps refreshing: new relays,
  revocations and rotated keys still reach it.
- The Xray config from `client-config` uses whichever of the server, the
  relays and the CDNs answers, on its own. An app holding several links lets
  the user pick one that works.
- To hand a link over, show its QR code in person, send a file, or use any
  channel that still gets through. A link or subscription URL is a credential
  that also names your relay, so avoid a messenger whose operator may read or
  hand over messages. If a link may have leaked, delete the device from
  `vless_clients` and give it a new one.
- If a relay's address is blocked, move the relay to a new machine or
  address under the same domain. Its links and subscription URLs work again
  as soon as DNS points there. Devices with links through other relays carry
  on meanwhile.
