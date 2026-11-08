# dotdash 0.3.0

### Added

- Optional subscriptions (`subscription`): each device gets a URL on the cover site that serves its links, which `client-config` prints and the app refreshes by itself, so a revocation or a key rotation reaches devices without resending links. Rotating `subscription_key` moves every URL.

- An optional second proxy for IPv6 (`upstream6_host`, with its own credentials), for an upstream that leaves over IPv4 only: destinations with an IPv6 address, sites with both included, leave through it, and the rest through the first. Neither falls back to the other, and `doctor` names the one that fails.

### Changed

- The Xray config `client-config` prints checks all its entries at once every 30 seconds, where it checked one a minute in turn, so it leaves an entry that stops answering within about half a minute instead of up to several minutes. That is two small requests a minute per entry.
