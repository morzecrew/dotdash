# dotdash 0.5.1

A patch release on 0.5.0. It needs morzer 0.15.0, as 0.5.0 did, so there is nothing to update first:

```sh
sudo morzer update --stage
sudo morzer update --to 0.5.1
```

### Deprecated

- The `xdns-xhttp-reality` profile goes in 0.6.0, not in this patch release as 0.5.0 announced: removing it would break a server still set to it. `xdns,xhttp-reality` deploys the same; switch before 0.6.0 with `sudo morzer config set installation.profile=xdns,xhttp-reality`.

### Fixed

- The command `relay-config` prints for the relay machine's last step, `relay-entry`, now includes `--output`; without it morzer ran the task and showed nothing, not the line the `relays` parameter needs.
