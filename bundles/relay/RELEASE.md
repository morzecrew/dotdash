# dotdash-relay 0.11.0

Released with dotdash 0.11.0. Nothing needs doing before updating from 0.10.0, and `morzer rollback` back to it works once `name` is unset (`sudo morzer config unset name`). It needs morzer 0.18.0, as 0.10.0 did. Set the new `name` (below), print the relay's line again with `relay-entry` and replace it in the server's `relays`; a server before 0.11.0 ignores the name.

```sh
sudo morzer update --stage
sudo morzer update --to 0.11.0
```

### Added

- A relay's `name` parameter: a label that devices' links through it carry in place of `relay <n>`, such as `edge-1 · reality`. `relay-entry` ends the relay's line with `name=`, and a name an earlier relay took goes by the number.

### Changed

- Links are named `<route> · <transport>`, such as `server · reality`, `relay 2 · hy2` or `relay · cdn`, without the device's name, which an app showed on every link. Apps pick up the names at the next subscription refresh; hand-imported links keep the old ones, and outbound tags are unchanged.

### Fixed

- The server's `relay-config` prints the relay's `dotdash_xhttp_path` before the `dotdash_link=xhttp-reality` that needs it. In the old order the relay switched to XHTTP with no path, failed its health check and stayed cut off until morzer gave up.
