# dotdash 0.14.0

Nothing needs doing before updating from 0.13.0, and `morzer rollback` back to it works once no `direct` line is left in `upstreams` (`sudo morzer secret edit upstreams`). A relay line ending in `standby` is an ordinary relay again under 0.13.0. It needs morzer 0.18.0, as 0.13.0 did.

- **A server already on a residential line** can use its own address as a way out: a `direct` line in `upstreams`, alone or beside proxies as their backup or fallback.
- **A relay kept for when the others fail:** `standby` at the end of its line in `relays`. Devices get its links last at their next subscription refresh, and their Xray configs leave it unchecked until every other link fails.

```sh
sudo morzer update --stage
sudo morzer update --to 0.14.0
```

### Added

- `standby` at the end of a relay's line in `relays` keeps that relay idle while others get through: devices get its links last, and their Xray configs, dotdash-client's included, don't check them and use them only once every other link fails. The manager's roster takes `standby` on a relay.

- A `direct` line in `upstreams` makes the server's own address a way out, for a server already on a residential line: alone, or beside proxies as their backup or fallback. `doctor` asks it from the server itself.
