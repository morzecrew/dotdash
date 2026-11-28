# dotdash 0.19.0

Nothing needs doing before updating from 0.18.0: the server still reads the relay lines of 0.18, so every link keeps working. The update generates a new secret, `relay_seed`. `morzer rollback` back to 0.18.0 works once no `relay/1` line is left in `relays`. It needs morzer 0.18.0, as 0.18.0 did.

- **With relays:** update every server first, then each relay, one at a time, as [Moving from 0.18](https://morzecrew.github.io/dotdash/relay/gateway/#moving-from-018) says. A relay of 0.19 needs servers of 0.19, and its update can't be rolled back.
- **Several servers in a group:** each generates a `relay_seed` of its own. Copy the first one's to the others before any `relay/1` line goes in, as the other shared secrets.
- **`name`** names the group: `--set name=<group>` with the update. Set, it renames the servers' own links (`s1 · reality`); unset, links read as before.
- **The next release reads no relay line of 0.18:** `sudo morzer task run client-config --output -- --check` warns of each one left.
- **With the manager:** update the servers with the manager of 0.18 first, then this release's manager and the relays together.

```sh
sudo morzer update --stage
sudo morzer update --to 0.19.0 --set name=<group>
```

### Added

- The server reads a relay's `relay/1` line in `relays` and lets the relay in by an id derived from a new generated secret, `relay_seed`, and the relay's name and nonce. Nobody adds a relay to `vless_clients` again, and deleting its line revokes it. Copy `relay_seed` to every server of the group, as the keys.

- A server `name` parameter, the server group's: relays know the group by it, and the servers' own links are named by it in place of `server` (`s1 · reality`, `s1 2 · xhttp` with several servers). Unset, links read as before.

- `relay-config -- <relay>` prints the one `server/1` line that relay keeps for this server group: the servers, their port and keys, and the relay's id here. It needs `name` and the relay's `relay/1` line; for a relay of 0.18, named as its client in `vless_clients`, it prints what it did.

- A `relay_flags` parameter, one `<name> [standby] [off=<path>[,<path>]] [split]` line per relay: what the server or the manager decides about a relay, kept off its line, so a change restarts no Xray.

- `client-config -- --relay <relay> [<device>]` prints only that relay's subscription URL and, with `--full`, its links. The subscription still carries every relay the device gets.

- The server's facts carry its `name`.

- The server publishes each `relay/1` relay's device list, with subscriptions on or off, at an internal name only that relay's tunnel reaches. Xray hands those names to a new Caddy listener on port 8085, never published, and blocks every other user asking for one. The public site never serves a list.

- `client-config --check` warns of each relay line of 0.18 left in `relays`, which the next release won't read, and of a client in `vless_clients` named as a `relay/1` line's relay: likely that relay's client of 0.18, which nothing needs once the relay runs this release.

### Changed

- **Breaking for anything that reads link names:** with `name` set, the servers' own links are named by it, not `server`.

- An edit to `relays` restarts the server's Xray, which now lets the `relay/1` lines' relays in. Lines of 0.18 still work, their relays coming in by their clients in `vless_clients`. `standby`, `off=`, `split` and `name=` on a `relay/1` line are warned of and ignored: they go in `relay_flags`.

- Two `relay/1` lines with one name, ignoring case, or one whose client name, `relay-<name>`, a device in `vless_clients` has, fail the change that brings them, as Xray refuses them too. A relay's old line in `vless_clients` named exactly `relay-<name>` has to be renamed or dropped before its `relay/1` line goes in.

### Fixed

- `client-config` prints no subscription URL through a relay whose every path is off in `relay_flags`, a burnt relay or a spare the manager holds back, as it already printed no link through it: the URL gave devices the address of a relay they were not to use.

- `relay-config`, for a relay of 0.18, prints that release's `init` (`dotdash-relay:0.18.0`): `stable` is now a gateway relay, which refuses the `dotdash_*` values it sets.

- A cover app's own headers reach visitors, on the server and on own-site relays: Caddy sets `Referrer-Policy`, HSTS and `X-Content-Type-Options` only where the app sends none, and removes only its own `Server` and `Via`. Every site had answered with the same headers whatever the app, which no stock install does.
