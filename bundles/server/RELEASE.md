# dotdash 0.17.0

Nothing needs doing before updating from 0.16.0. `morzer rollback` back to it works once no `vless_clients` line ends in a kind, the `openflux` and `device-traffic` profiles are off, and `cdn_extra`, `happ_routing`, `openflux_channels` and `call_provider` are unset (`sudo morzer config unset cdn_extra happ_routing openflux_channels call_provider`). It needs morzer 0.18.0, as 0.16.0 did.

- **Device kinds:** update the relays to 0.17.0 first, since a relay's its `vless_clients` carries the same lines, as the manager writes them or you copy them, and 0.16.0 refuses one ending in a kind. Then add ` desktop` after the name of each desktop or laptop in `vless_clients`, with `sudo morzer secret edit vless_clients`. Those devices lose their CDN links at their next subscription fetch and keep the others.
- **A relay's `origin=` with several names, or a name with a path** (`<name>/<path>`), gives devices a link through each from this release on; an earlier server gives no link at all through such a field.
- **A CDN that asks for XHTTP settings of its own** gets them from `cdn_extra`, pasted as the CDN gives them ([CDN](https://morzecrew.github.io/dotdash/server/cdn/#a-cdn-that-fetches-in-plain-http)).
- **`openflux`, `device-traffic` and `happ_routing`** are new and off until set. Facts run hourly before each fleet publish: nothing to do.

```sh
sudo morzer update --stage
sudo morzer update --to 0.17.0
```

### Added

- `cdn_extra` on the server: the XHTTP settings a CDN or its gateway asks for, by name, pasted as the CDN gives them. Links and outbounds through that name carry them in place of dotdash's own, so a CDN that wants its own settings needs no change to dotdash. Settings Xray refuses are left out with a warning. The manager's roster takes `cdn_extra` too.

- A device's kind, `desktop` or `mobile`, after its name in `vless_clients`. A desktop gets no CDN link: none through the server's `cdn_hosts`, none through a relay's `cdn=` or `origin=`, and nothing through a relay that offers CDN links alone. CDNs serve restricted mobile networks, some paid by the gigabyte, where a desktop moves the most. A changed kind reaches the device at its next subscription fetch. The manager's roster takes `desktops`, a list of its devices. Servers and relays take such lines from this release on: update the relays before giving a device a kind, and take the kinds off before rolling back to an earlier release, whose image refuses them.

- An `openflux` profile on the server, the way in left when nothing else gets through: an [OpenFlux](https://github.com/p1neappleXpress/OpenFlux) exit for each device listed in `openflux_channels`, which that device's OpenFlux app meets on a room or call of a service a restricted network still lets through. Each exit opens the device's connections through the gate, so they leave through the upstreams; UDP goes the same way, or nowhere with `upstream_udp` off. Only the carrier's own connections leave directly. A line names its carriers by short kinds: `co` makes its own rooms, and `tm` its own call with the new `call_provider` and `call_token`, or takes a call link of yours. Each device's key, rooms, call and link are kept on a volume, and a device deleted from `vless_clients` loses them. The `openflux-link` task prints the link for the app. OpenFlux 0.17.1, from platform-images' `openflux` image. In the lab `tm` carried 8 Mbit/s with no stall but 2.3 Mbit/s even idle, `co` 1-2 Mbit/s; the exit's OpenFlux version must match the apps'.

- A `device-traffic` profile on servers and relays: Xray counts the bytes each device moves, and the facts carry the counts by device name to the authority. The manager adds them up by day and names a device whose day reached five times its median and at least 2 GB, as a link passed around shows: `sync` for yesterday and today, `report` for the last 30 days. Only counts, never an address, and not in the metrics files. Xray counts a device by its name, so a `vless_clients` line with no name isn't counted; the manager names every device. A relay counts its own devices, which the server sees as the relay alone. The facts task, with the other tasks of its service, runs in Xray's namespace under the profile.

- `happ_routing` on the server: a routing profile in Happ's own JSON, which every subscription then carries in Happ's `routing` header (relays' too). Happ adds it and turns it on, so the sites it lists as direct go around the tunnel on every Happ device. Other apps ignore it.

### Changed

- A relay's `http_origin_host` takes several names, comma-separated, for a rented CDN that gives more than one, such as a spare for when one is blocked. Devices get a 4 KiB `relay · cdn` link and outbound through each, numbered with the relay's other CDN links: `relay · cdn 1`, `relay · cdn 2`. A name may carry a path of the CDN's own, `<name>/<path>`, which its links take in place of the CDN path. The server and the manager read the list from the relay's line as they read one name.

- Servers' and relays' facts run again before every fleet publish, hourly (morzer's `published.refresh`), so the `device-traffic` counts reach the manager within the hour. Without the profile their output stays the same and so do the facts; each run is one task operation in the journal and the attestations (`retention.attestations`).
