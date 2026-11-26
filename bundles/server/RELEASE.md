# dotdash 0.18.0

Check the first two points before updating from 0.17.0: either one now makes the update fail and roll back. The update generates a new secret, `cdn_xhttp_path`, the path CDNs in front fetch this server by. `morzer rollback` back to 0.17.0 works, and devices' `cdn_hosts` links go back to the plain path at their next subscription refresh. It needs morzer 0.18.0, as 0.17.0 did.

- **`resolve=upstream` beside a `direct` line in `upstreams`** is refused. Set `sudo morzer config set resolve=gateway` first.
- **A line in `relays` or `cdn_extra` that the server would leave out** fails the update, named by its line number and field (the new `lists` health check). Fix it with `sudo morzer config edit relays` and update again. A field the server doesn't know, a taken name or a pool member naming nothing still only warns.
- **Devices' `cdn_hosts` links** take a disguised path of their own at their next subscription refresh. A link imported by hand keeps working, as the plain path stays.
- **After the update,** the 4 MiB subscriptions volume is unused: `sudo docker volume rm dotdash_subscription`.
- **With the manager:** update the servers before its next sync, since a server older than 0.18.0 ignores a relay's whole `off=` once it holds `cdn:<name>`. Then run `join` again for each machine joined before, so it backs up under `backups/<name>/` on the target. Its backups at the target's root stay until you delete them.
- **Under `openflux`,** the exits' connections now follow the rules devices get: BitTorrent, port 25, private addresses, `resolve` and `ipv6`.

```sh
sudo morzer update --stage
sudo morzer update --to 0.18.0
```

### Added

- The server's `relay-config` ends with the count and digest of the devices it hands a relay, and the relay's `relay-entry` and facts give the same of its own copy, so a stale copy that rejects new devices or still lets in deleted ones shows. The manager's `status` says when a relay's list isn't the one it sent.

- The release and dev keys' public halves, in the README and the docs' Releases section: `morzer init --signing-key` checks even the first release against them, with no access to the repository's variables.

- A server's facts carry `cert_days`, the whole days left on the certificate Caddy serves for its domain, so the authority can warn before a failed renewal breaks XHTTP, Hysteria2 and the CDN paths while REALITY keeps working. Left out while there is no certificate yet.

- A `relays` line's `off=` takes `cdn:<name>` for a CDN in front of that relay which gets nothing through: devices lose that CDN's links and outbounds and keep the relay's others, and a cdn-only relay left with no CDN drops out. Until now a `cdn:` token voided the whole `off=` field.

### Changed

- A `relays` line with a field the server doesn't know, such as a mistyped `cdn_path=`, gets a warning naming the field and the line, where the relay used to lose that transport unsaid.

- The cover app behind a server sees each visitor's own address in `X-Forwarded-For`, not Xray's, so its per-address limits and lockouts hold per visitor. The gate and Xray hand the address on in PROXY headers, which Caddy takes from Xray alone. HTTP/3 visitors still show as Xray.

- `cdn-check` also checks a relay's `origin=` names, and for every CDN name whether its links' path reaches Xray behind it, ends at the site's 404 (a stale path, or a door that refused the CDN), or gets a 5xx or nothing (the CDN doesn't reach its origin). It exits 1 on any of those too.

- A `relays` or `cdn_extra` line, or a field of one, that the server would leave out now fails the change that brings it, by its line number and field, and morzer rolls it back: a new `lists` health check, which `doctor` runs too. A field it doesn't know, a taken name or a pool member naming nothing still only warns.

- The server's `cdn_hosts` links go by a path of their own (a new `cdn_xhttp_path` secret), disguised as a relay's CDN links are, so a CDN's logs show neither the direct XHTTP path nor its padding. Devices take them at their next subscription refresh; links imported by hand still work, as the plain path stays.

- The server's OpenVPN upstream runs OpenVPN 2.6.23, as the client's kill switch does.

### Fixed

- A `servers` that names no server, such as ` , `, stopped `client-config` and the subscriptions with no message. It now means this server alone, as an empty `servers` does, with a warning.

- Subscriptions fit about 1000 devices, up from about 10 to 30, on a new 512 MiB in-memory volume that takes only what the files fill. The 4 MiB `dotdash_subscription` before it is left behind, empty, for `sudo docker volume rm dotdash_subscription` after the update.

- A device's subscription URL no longer answers 404 while the service writes the files again after a change: the files of deleted devices or a rotated key go first, and each live one is replaced in place. A full volume now leaves the last files served, where every URL used to go.

- The docs' recipe for several servers copies `kcp_seed` and `subscription_key` too, and says they need the same profiles and transport parameters. Servers set up by the old one gave dead mKCP links to each other, and a 404 to a subscription a relay fetched from the other.

- A server takes `hello_split` from the manager's desired state. The server didn't list it as managed, so once the manager's canaries found a server's name blocked by SNI, morzer refused that server's whole document, keys and devices included, until the split was off again.

- `hysteria2_port=53` beside the DNS tunnel is refused when the change is made, as `kcp_port=53` is, rather than failing when the gate publishes both on UDP 53.

- Under the `hysteria2` profile, a visitor over HTTP/3 reaches the cover site with the domain as its Host, as over TCP. Hysteria2's masquerade sent `caddy:443` in its place, so an app's redirects and cookies over HTTP/3 named `caddy`.

- The server's redirect to HTTPS on port 80 no longer sends `Server: Caddy`, which the site's own answers on 443 already left out. It is otherwise the redirect Caddy makes itself.

- With `cover` naming an app, the site's answers no longer carry `Via: 1.1 Caddy`, which Caddy adds to whatever it proxies and which named it as `Server` would.

### Security

- `bootstrap.sh` runs morzer's installer from a pinned commit, checked by sha256, where it piped whatever a movable tag served into `sh`. It also trusts Docker's apt key only when the file holds that one key, by its fingerprint.

- A server takes a `relays` line only when its host, site, public key, short id, VLESS encryption and XHTTP path each have their shape, and gives no mKCP link through a `kcp=` field that isn't whole. A bad line is left out and named by its line number, so a tampered one can't rewrite or break every device's config.

- `servers` and `cdn_hosts` entries that aren't host names are left out with a warning, and an `xdns_domain` that isn't one stops `client-config`, instead of reaching every device's links and Xray config.

- With `direct=false`, subscriptions carry no title (`Profile-Title`), which names the exit in Happ and Hiddify: with a `direct` line in `upstreams` it was the server's own address, shown to every device that `direct=false` keeps it from.

- Under the server's `openflux` profile, the exits' connections go through Xray, so the rules devices get apply to them: BitTorrent and trackers, mail on port 25, private addresses and the server's networks are blocked, and `resolve` and `ipv6` hold. They went to the gate, past all of it.

- `resolve=upstream` beside a `direct` upstreams line is refused: the apply rolls back and `doctor` names it. The gate resolved devices' names on the server, so a device reached its containers by name, `xray` and `gate` among them, past Xray's rules. Use `resolve=gateway`.
