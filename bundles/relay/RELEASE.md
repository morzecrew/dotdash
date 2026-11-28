# dotdash-relay 0.19.0

Released with dotdash 0.19.0. **Breaking:** a relay of 0.19 needs servers of 0.19, a `name` and a `servers` line from them, and idles until it has them. Update the servers first, then each relay, one at a time, as [Moving from 0.18](https://morzecrew.github.io/dotdash/relay/gateway/#moving-from-018) says. `morzer rollback` back to 0.18.0 is refused, as this release drops values 0.18 requires: restore the pre-update backup instead. Unattended updates leave it staged for you. It needs morzer 0.18.0, as 0.18.0 did.

- **Its `dotdash_*` values and `vless_clients` are dropped** with the update. The `servers` secret takes their place, a `server/1` line per group, which `relay-config -- <name>` prints on one of the group's servers.
- **`via`** is now a secret of `relay/1` lines: move the relays it goes through first.
- **`dotdash_link` is now `server_link`:** a relay that went to its servers over XHTTP with REALITY takes `--set server_link=xhttp-reality` with its update.
- **Health** says only that Xray and its gateway's agent work. Watch `dotdash_group_live`, or `sudo morzer task run servers --output`, for whether a group answers.

```sh
sudo morzer update --stage
sudo morzer update --to 0.19.0 --set name=<relay>
```

### Added

- Every relay is a gateway: one relay carries devices of several server groups, each to its own group's servers and exit alone. A new `servers` secret takes one `server/1` line per group, and the relay fetches each group's devices itself with no restart. A group whose servers are down gets nothing, never another's exit.

- A relay's `relay-entry` prints its `relay/1` line, the one line every server's `relays` takes: `relay/1 <name> <nonce> <host> <site> <public key> <short id> <encryption>`, then its transports' fields. `nonce` is a new generated secret, from which, with the name, each server derives the relay's id.

- A relay's `servers` task prints each server group's state, `live`, `down`, `refused` or `starting`, with its servers, devices and the age of its list. The facts carry the same under `groups`, and the `metrics` profile adds `dotdash_group_live`, `dotdash_group_devices` and `dotdash_group_list_age_seconds`.

- A relay's `entry-check` tries each entry for each live group, as a checker the relay adds to each group with a random id, a line per entry per group (`reality@a`); a group that is not live has its entries left out.

- A relay's `server_link` (in place of `dotdash_link`) reaches each group's servers over XHTTP with REALITY on its line's `xr=`, and `tunnel_group` names the group whose servers a cover app's `tunnel_host` is reached through.

### Changed

- **Breaking for relays:** `servers` replaces a relay's `dotdash_*` values and `vless_clients`, `via` takes `relay/1` lines, and `name` is required. Update the servers first; a relay idles until its `servers` line is in. `morzer rollback` is refused: restore the pre-update backup (the relay's docs, Moving from 0.18).

- **Breaking for relay monitoring:** a relay's health check says only that Xray runs and its gateway's agent reached it in the last two minutes, so an idle relay, or one whose groups are all down, is healthy. Watch `dotdash_group_live` for whether a group answers.

- **Breaking for anything that reads a relay's facts:** `clients` and `via` are gone, `name`, `nonce` and `groups` are new, and device traffic is counted per `<device>@<group>`. From an authority, a relay takes only `servers`, `via`, `ipv6`, `server_link`, `via_link`, `via_fingerprint` and `tunnel_group`.

- A subscription through a relay goes to the device's own group by its token's first 12 hex characters, so URLs keep their form and the relay never holds a whole token. Caddy no longer restarts when servers change. A token no group lists, or a group that is down, gets the relay's site.

### Fixed

- A cover app's own headers reach visitors, on the server and on own-site relays: Caddy sets `Referrer-Policy`, HSTS and `X-Content-Type-Options` only where the app sends none, and removes only its own `Server` and `Via`. Every site had answered with the same headers whatever the app, which no stock install does.
