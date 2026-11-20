# dotdash 0.11.0

Nothing needs doing before updating from 0.10.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.10.0 did.

- **Link names:** links are named `<route> · <transport>`, such as `relay 2 · hy2`, with no device name (below). An app shows the new names at its next subscription refresh; links imported by hand keep their old names until imported again. The Xray config's outbound tags are unchanged.
- **Relay names:** a relay's `name=` field, which its 0.11.0 `relay-entry` prints, names its links. A 0.10.0 server ignores it.

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
