# dotdash-canary 0.17.0

Released with dotdash 0.17.0. Nothing needs doing before updating from 0.16.0, and `morzer rollback` back to it works once `burst_check` is unset, if you set it. It needs morzer 0.17.0 or later, as 0.16.0 did.

- **The burst check** is on by default. `sudo morzer config set burst_check=false` turns it off.

```sh
sudo morzer update --stage
sudo morzer update --to 0.17.0
```

### Added

- The canary ends its `facts` with a burst through REALITY: six connections at once, then one more (`burst_check`, on by default). A network that freezes a device opening several connections to one address within a fraction of a second freezes REALITY with Vision on every page while a check of one connection passes; the canary now reports REALITY down there, with `burst: true` and `blocked_by: burst`, and the manager takes REALITY off that relay's links as for any blocked path.
