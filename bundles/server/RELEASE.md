# dotdash 0.16.0

Nothing needs doing before updating from 0.15.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.15.0 did.

- **Subscriptions** ask the apps that read it to refetch every 6 hours, and the server drops announces to public BitTorrent trackers and mail on port 25: nothing to do for either.
- **A relay's line ending in `origin=`** (its new `http-origin` profile) gives devices a link through that CDN from this release on; an earlier server leaves the field out.
- **Devices on v2rayNG with the Xray config** can have a password on its local proxy, for apps that look for a VPN: `sudo morzer task run client-config --output -- --local-auth phone`, then the printed user and password in v2rayNG's settings.

```sh
sudo morzer update --stage
sudo morzer update --to 0.16.0
```

### Added

- `client-config --local-auth` prints the Xray config with a password on its local SOCKS, the same on every run, and no local HTTP proxy, for v2rayNG's "Local proxy username and password". Other apps on the phone then find no open proxy to try. devices.md says how to do the same in v2rayNG with links or a subscription.

- A subscription asks the apps that read `Profile-Update-Interval` (Happ, Hiddify) to fetch it again every 6 hours, so new relays, rotated keys and revoked devices reach them without a manual refresh. A relay's subscription carries it too.

- A relay's `http-origin` profile: a door in plain HTTP on `http_origin_port` for a CDN that ends TLS at its own edge and fetches the origin unencrypted, as some rented for restricted networks do. It answers only the gateway addresses in `http_origin_from`, and only on the CDNs' path, which it passes to Xray's XHTTP inbound. `http_origin_host` reaches the server's line as `origin=`, and devices get a `relay · cdn` link through it uploading 4 KiB at a time. `relay-entry` prints the port and the `xhttpSettings` to give the CDN. The manager carries `origin=` too.

### Changed

- The server drops announces to public BitTorrent trackers, by the trackers' names, and mail on port 25, beside the BitTorrent handshakes it already dropped. Upstream providers forbid both, and an announce puts the line's address in public swarms. Encrypted peer connections still look like any other traffic.
