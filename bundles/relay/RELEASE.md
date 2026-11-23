# dotdash-relay 0.14.0

Released with dotdash 0.14.0. Nothing needs doing before updating from 0.13.0, and `morzer rollback` back to it works once `via` and its settings are unset (`sudo morzer config unset via via_link via_fingerprint`). It needs morzer 0.18.0, as 0.13.0 did.

- **To go through another relay instead of the servers,** put that relay's `relay-entry` line in `via`. The other relay needs no update; with `via_link=xhttp` it needs `own-site`. Set `via_fingerprint=none` on that leg for a relay that only ever talks to the other one.

    ```sh
    sudo morzer config edit via
    ```

```sh
sudo morzer update --stage
sudo morzer update --to 0.14.0
```

### Added

- A relay can go through other relays instead of the servers: `via` takes their lines as `relay-entry` prints them, reached by REALITY or, with `via_link=xhttp`, XHTTP through their own sites. The servers never see its address, for a relay on an address worth keeping. The manager's roster takes both.

- A relay's `xhttp` `via` leg takes `via_fingerprint`, the TLS client hello it shows the relay it goes through. `none` drops the browser mimicry for Xray's own TLS stack, which looks like a server fetching from another rather than a phone; the default, `chrome`, is unchanged. The manager's roster takes it.
