# dotdash-client 0.13.0

Released with dotdash 0.13.0. Nothing needs doing before updating from 0.12.0, and `morzer rollback` back to it works once `cdn` is unset (`sudo morzer config unset cdn`). It needs morzer 0.17.0 or later, as 0.12.0 did.

- **To leave links through a CDN out,** set `cdn=skip`. Behind a server before 0.13.0, it leaves out the server's own CDN links but not a relay's.

    ```sh
    sudo morzer config set cdn=skip
    ```

```sh
sudo morzer update --stage
sudo morzer update --to 0.13.0
```

### Added

- dotdash-client's `cdn=skip` leaves links through a CDN out: the client never picks one, nor probes it. Telling a relay's CDN links apart needs a dotdash server of 0.13.0 or later.
