# dotdash 0.13.0

Nothing needs doing before updating from 0.12.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.12.0 did.

- **Devices' Xray configs:** a relay's CDN outbounds get new names and come last. Devices pick them up at their next subscription refresh. Share links don't change. A dotdash-client with the new `cdn=skip` needs this release to leave a relay's CDN links out, and not only the server's own.

```sh
sudo morzer update --stage
sudo morzer update --to 0.13.0
```

### Changed

- In devices' Xray configs, a relay's CDN outbounds are named `dotdash-cdn-relay-<n>-<m>` (was `dotdash-relay-<n>-cdn-<m>`) and come after every other outbound, so traffic the balancer can't place goes to a CDN only when there is no other link.
