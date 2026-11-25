# dotdash-relay 0.17.0

Released with dotdash 0.17.0. Nothing needs doing before updating from 0.16.0. `morzer rollback` back to it works once no `vless_clients` line ends in a kind, the `device-traffic` profile is off, and `http_origin_host` holds one name, with no path. It needs morzer 0.18.0, as 0.16.0 did.

- **Update this relay before the server's devices get a kind:** its `vless_clients` carries the same lines, as the manager writes them or you copy them, and 0.16.0 refuses one ending in a kind.
- **`http_origin_host` takes several names**, comma-separated, where the CDN gives more than one, and a name may carry a path the CDN gives with it, `<name>/<path>`; the settings such a name needs go in the server's `cdn_extra`. Run `relay-entry` again and put its line in the server's `relays`. A line with several names or a path needs the server at 0.17.0, as an earlier one gives no link through it.
- **`relay-entry`** prints the `http-origin` door's port and settings again.

```sh
sudo morzer update --stage
sudo morzer update --to 0.17.0
```

### Added

- A device's kind, `desktop` or `mobile`, after its name in `vless_clients`. A desktop gets no CDN link: none through the server's `cdn_hosts`, none through a relay's `cdn=` or `origin=`, and nothing through a relay that offers CDN links alone. CDNs serve restricted mobile networks, some paid by the gigabyte, where a desktop moves the most. A changed kind reaches the device at its next subscription fetch. The manager's roster takes `desktops`, a list of its devices. Servers and relays take such lines from this release on: update the relays before giving a device a kind, and take the kinds off before rolling back to an earlier release, whose image refuses them.

- A `device-traffic` profile on servers and relays: Xray counts the bytes each device moves, and the facts carry the counts by device name to the authority. The manager adds them up by day and names a device whose day reached five times its median and at least 2 GB, as a link passed around shows: `sync` for yesterday and today, `report` for the last 30 days. Only counts, never an address, and not in the metrics files. Xray counts a device by its name, so a `vless_clients` line with no name isn't counted; the manager names every device. A relay counts its own devices, which the server sees as the relay alone. The facts task, with the other tasks of its service, runs in Xray's namespace under the profile.

### Changed

- A relay's `http_origin_host` takes several names, comma-separated, for a rented CDN that gives more than one, such as a spare for when one is blocked. Devices get a 4 KiB `relay · cdn` link and outbound through each, numbered with the relay's other CDN links: `relay · cdn 1`, `relay · cdn 2`. A name may carry a path of the CDN's own, `<name>/<path>`, which its links take in place of the CDN path. The server and the manager read the list from the relay's line as they read one name.

- Servers' and relays' facts run again before every fleet publish, hourly (morzer's `published.refresh`), so the `device-traffic` counts reach the manager within the hour. Without the profile their output stays the same and so do the facts; each run is one task operation in the journal and the attestations (`retention.attestations`).

### Fixed

- A relay's `relay-entry` prints the `http-origin` door's port and the `xhttpSettings` for the CDN's form again. 0.16.0 never handed the task the port, so it printed neither, and the line carried no `cdnpath=` until `http_origin_host` was set.
