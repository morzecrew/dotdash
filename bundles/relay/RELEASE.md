# dotdash-relay 0.12.0

Released with dotdash 0.12.0. Nothing needs doing before updating from 0.11.3. It needs morzer 0.18.0, as 0.11.3 did. The update generates a new secret, `cdn_xhttp_path`, the path CDNs in front fetch the relay by.

- **A relay with CDNs in front (`cdn_hosts`):** after updating, print its line again and replace it in `relays` on the server (`sudo morzer config edit relays`), with the server on 0.12.0. The line now ends in `cdnpath=…`, and devices' CDN links take that path, disguised. A relay without `cdn_hosts` needs nothing.

    ```sh
    sudo morzer task run relay-entry --output -- <address>
    ```

- **Rollback:** `morzer rollback` back to 0.11.3 works, but once the line with `cdnpath=…` is in `relays`, the relay's CDN links fail until its line from 0.11.3 replaces it there.

```sh
sudo morzer update --stage
sudo morzer update --to 0.12.0
```

### Added

- A relay's CDN links take a path of their own (the relay's new `cdn_xhttp_path`, `cdnpath=` on its line in `relays`), so a CDN in front never learns the path devices reach the relay by directly, and look less like a tunnel to it: session, sequence and padding in cookies, no event-stream type.
