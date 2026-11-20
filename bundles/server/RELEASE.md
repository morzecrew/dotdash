# dotdash 0.10.0

Nothing needs doing before updating from 0.9.1 or 0.9.0, and `morzer rollback` back to either works. It needs morzer 0.18.0, as they did.

- **Link names:** links are named `<device> | <transport>`, after what they go through, no longer after its host (below). An app shows the new names at its next subscription refresh; links imported by hand keep their old names until imported again. The Xray config's outbound tags are unchanged.
- **The subscription's name:** with `subscription=true`, the server now asks two IP lookup services through its upstreams, at start and every ten minutes, for its exit's address and country (`exit_ipv4_url`, `exit_info_url`). Point them at services of your choice in the same form, or at your own.

```sh
sudo morzer update --stage
sudo morzer update --to 0.10.0
```

### Added

- A relay with a site of its own serves Hysteria2 too, under that site's certificate (`installation.profile=own-site,hysteria2`, UDP `hysteria2_port`, 443). Its `relay-entry` line ends with `hy2=<port>`, and devices get a `<device> | hy2 | relay` link and outbound through it.

- A device's subscription names itself after the server's exit, its country's flag and IPv4 address (`Profile-Title`), so the apps that show a name (Happ, Hiddify) show where traffic leaves instead of the server's domain. The server asks every ten minutes, through the upstreams (`exit_ipv4_url`, `exit_info_url`).

- `dotdash-manager` gives a canary watching a relay with Hysteria2 the relay's port (`dotdash_hysteria2_port`), so the canary's `hysteria2` profile checks it, and a relay whose Hysteria2 its canaries can't get through loses that link (`off=hysteria2`).

### Changed

- Links are named `<device> | <transport>`, with ` | relay`, ` | cdn` or ` | relay, cdn` through a relay or a CDN, numbered where there are several (`relay 1, cdn 2`), and ` | server <n>` with several servers, in place of the host names they used to carry: an app shows no relay, CDN or server name.

- The server's gate probes each upstreams line every 10 s instead of 30. When a line goes silent, new connections move to another after about 8 s on average and 12 at most, instead of 18 and 31.

- `dotdash-manager sync` and `rotate swap` read the machines' facts eight at a time instead of one after another, so a fleet of many machines syncs in a fraction of the time.

### Fixed

- Under the `metrics` profile, a change of a secret after `morzer restart xray` restarts Xray again instead of failing: the exporters reach Xray's and the gate's metrics on an internal network of their own rather than sharing their network namespaces, which a recreate left them stranded in. The same holds on the relay.

- A device's subscription through an own-site relay serves its links again. The relay's Caddy passed the request on with a `Via` header, which the server takes for a CDN's, so the server answered with its site, and apps reported a config they could not parse.

- The relay's `cover-site` health check checks its own site under the `own-site` profile: that Caddy is healthy and the app `cover` names answers. It used to report the profile off and pass, so `config set cover=` was never undone when the site could not reach the app.

- `dotdash-manager` runs one at a time on its state, and a second run waits. Two overlapping runs, such as a timer's `sync` during a `rotate`, could lose each other's changes. The state is synced to disk before it replaces the old one, and `sync --dry-run` no longer writes it.

- `dotdash-manager sync` judges a relay only by canary readings within 90 minutes of the newest. A canary that went quiet used to hold a relay up with an old success while another canary found it blocked.

- `bootstrap.sh` installs morzer 0.18.0, which dotdash 0.9.0 needs, instead of 0.17.0. On Ubuntu 22.04 and Debian 11, which ship no minisign, it installs minisign's own release, checked against a pinned sum, where it used to stop at "Unable to locate package minisign".
