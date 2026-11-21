# dotdash 0.12.0

Nothing needs doing before updating from 0.11.3, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.11.3 did.

- **CDN links through a relay:** they change once the relay is on 0.12.0 and its line in `relays` is replaced with the one its `relay-entry` now prints, which ends in `cdnpath=…` (see the relay's notes). Until then, a relay's line gives the plain CDN links, as before. Apps pick up the new ones at their next subscription refresh; a CDN link imported by hand has to be imported again.

- **If an app can't use the new CDN links,** delete `cdnpath=…` from the relay's line in `relays`: its CDN links go back to the plain ones.

```sh
sudo morzer update --stage
sudo morzer update --to 0.12.0
```

### Added

- A relay's CDN links take a path of their own (the relay's new `cdn_xhttp_path`, `cdnpath=` on its line in `relays`), so a CDN in front never learns the path devices reach the relay by directly, and look less like a tunnel to it: session, sequence and padding in cookies, no event-stream type.
