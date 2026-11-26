# dotdash-relay 0.18.0

Released with dotdash 0.18.0. Nothing needs doing before updating from 0.17.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.17.0 did.

- **A relay the manager runs** now takes `via`, `via_link` and `via_fingerprint` from it. One that took no change from the manager since `join` gets the whole document at the next sync.
- **`entry-check`** tries each entry as a device reaches it, and says why one fails: `sudo morzer task run entry-check --output`.
- **The update fails, and rolls back,** if `site`, `dotdash_servers`, `dotdash_address`, `dotdash_public_key` or a `via` line holds a quote, a backslash, a brace or whitespace. None of them needs one.

```sh
sudo morzer update --stage
sudo morzer update --to 0.18.0
```

### Added

- The relay's `entry-check` task tries each of its entries end to end as a device would, REALITY, XHTTP through its site, mKCP and Hysteria2, and says why one fails. The `http-origin` door keeps each request's address and status in memory, so the check can tell a firewall from docker-proxy hiding the CDN's addresses.

- The server's `relay-config` ends with the count and digest of the devices it hands a relay, and the relay's `relay-entry` and facts give the same of its own copy, so a stale copy that rejects new devices or still lets in deleted ones shows. The manager's `status` says when a relay's list isn't the one it sent.

- An own-site relay's facts carry `cert_days`, the whole days left on the certificate its site serves, so an authority can warn before it runs out: when it does, XHTTP, Hysteria2 and the CDN links through the relay stop while REALITY goes on. It is left out while Caddy has no certificate.

### Changed

- A relay's cover app sees each visitor's own address in `X-Forwarded-For`, where every visitor showed Xray's, so its per-address limits and lockouts no longer hit everyone at once. REALITY hands Caddy each connection behind a PROXY header that only Xray's network may send; the Hysteria2 masquerade still shows Xray's.

### Fixed

- A relay run by the manager takes `via`, `via_link` and `via_fingerprint` from it. The relay never declared them managed, so morzer refused the whole document that set or unset them, and such a relay took no change from the manager after `join`.

- A relay's `http-origin` profile without `own-site` is refused with a message that says to add `own-site`, in place of a Compose error about a service with no image.

- A relay's Hysteria2 hands a visitor without a login to its site with the Host the visitor sent, as over TCP. It sent `caddy:443`, so a cover app's redirects and cookies over HTTP/3 named another host than over TCP.

- A subscription token the servers don't have gets the relay's own site, as any other path does, where it got the server's 404 page through the tunnel. One request could tell an own-site relay apart, and might name its server.

- A relay's site names no server anywhere: port 80's redirect and the `http-origin` door dropped `Server: Caddy`, as port 443 already did, and every port drops the `Via: 1.1 Caddy` Caddy adds to what it passes back from a cover app, a server or Xray.

### Security

- A relay refuses a quote, backslash, brace or whitespace in `site`, `dotdash_servers`, `dotdash_address`, `dotdash_public_key` and each `via` line, set by hand or by an authority. Such a value could add keys to its Xray config or lines to its Caddyfile; the apply now fails and the relay stays as it was.
