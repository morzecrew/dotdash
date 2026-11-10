# Before and during a shutdown

In a shutdown, mobile networks in a region let through only addresses on an
allowlist. That covers domestic services and none of your servers abroad.
The server stops answering devices there, but a relay inside the country
and a domestic CDN still answer. Set them up and hand everything out
**before** it starts, while devices still reach the server.

## Before

1. **A relay with a site of its own** ([set one up](relay/install.md)), in a
   network that stays reachable. Give `relay-entry` the relay's domain
   rather than its IP: links and subscription URLs then name the domain, and
   moving the relay to a new address only takes a DNS change.
2. **A canary on a mobile line** ([canary](canary/index.md)), checking the
   relay. It alerts you when a way in stops working for devices like yours.
3. **A domestic CDN**, as one more way in ([CDN](server/cdn.md)). Expect the
   account to be closed one day.
4. **Every device** gets its links again once the relay and the CDN are in.
   With subscriptions on, give a device inside the country its subscription
   URL through the relay (`through the relay …` in `client-config`), not the
   server's. Its app then keeps refreshing its links during a shutdown.
5. **Test** on a phone with a SIM from the network you care about, using
   mobile data with Wi-Fi off and the relay link alone.

## During

- An app that can't fetch its subscription keeps the links it already has.
  With the URL through the relay, it keeps refreshing: new relays,
  revocations and rotated keys still reach it.
- The Xray config from `client-config` uses whichever of the server, the
  relays and the CDNs answers, on its own. An app holding several links lets
  the user pick one that works.
- To hand a link over, show its QR code in person, send a file, or use
  domestic mail (Yandex, Mail.ru), which allowlists let through. A link or
  subscription URL is a credential that also names your relay. If it may
  have leaked, delete the device from `vless_clients` and give it a new one.
  Avoid MAX, the state-run messenger.
- If a relay's address is blocked, move the relay to a new machine or
  address under the same domain. Its links and subscription URLs work again
  as soon as DNS points there. Devices with links through other relays carry
  on meanwhile.
