# dotdash-canary 0.18.0

Released with dotdash 0.18.0. Nothing needs doing before updating from 0.17.0. `morzer rollback` back to it works once `dotdash_cdn_hosts` and `dotdash_origin_host` are unset (`sudo morzer config unset dotdash_cdn_hosts dotdash_origin_host`); 0.17.0 reads only `https://` freeze and download URLs. It needs morzer 0.17.0 or later, as 0.17.0 did.

- **CDN checks:** the manager hands a canary the CDNs in front of its relay. By hand, set `dotdash_cdn_hosts` and `dotdash_origin_host` to the relay's `cdn_hosts` and `http_origin_host`, and the `dotdash_cdn_xhttp_path` secret to the `cdnpath=` of its line.
- **An `https://` `freeze_url`, `freeze_up_url` or `download_url`** now has its certificate checked, so a site with a certificate from its own CA fails every freeze check. Give such a site as `http://`.

```sh
sudo morzer update --stage
sudo morzer update --to 0.18.0
```

### Added

- A canary checks each CDN in front of the relay it watches, through the CDN as a device's CDN link goes, and gives each under `cdn` in its facts. The manager hands it the names and CDN path; by hand, set `dotdash_cdn_hosts`, `dotdash_origin_host` and the `dotdash_cdn_xhttp_path` secret.

### Changed

- The canary's `freeze_url`, `freeze_up_url` and `download_url` take `http://` as well as `https://`, and an `https://` one's certificate is now checked. A 64 KB freeze download not done in 40 seconds counts as stopped partway.

### Fixed

- The canary's freeze checks and `measure`'s downloads go through the transport they check. They went out over the canary's own network, so where that network froze the test site directly, every path read `blocked_by: freeze` and the manager took healthy relays out of devices' links.

- A canary under the hysteria2 profile restarts Hysteria2 when `dotdash_id` changes, so a rotated id no longer leaves it logging in with the old one.

- The canary refuses at render a `dotdash_server`, `dotdash_address` or `dotdash_public_key` holding a quote, a backslash, a brace or whitespace, so a value set by the manager can't reach into the canary's Xray config.
