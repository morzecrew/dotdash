# dotdash-client 0.17.0

Released with dotdash 0.17.0. Nothing needs doing before updating from 0.16.0, and `morzer rollback` back to it works once the `openflux` profile is off. It needs morzer 0.17.0 or later, as 0.16.0 did.

- **The `openflux` profile** is new and off by default. It needs the server's `openflux` profile and this device's link from the server's `openflux-link` task, in the `openflux_link` secret.

```sh
sudo morzer update --stage
sudo morzer update --to 0.17.0
```

### Added

- An `openflux` profile on the client: when every dotdash link fails its probe, Xray's balancer hands the traffic to an OpenFlux client, which reaches this device's OpenFlux exit on a dotdash server (the server's `openflux` profile) over a room or call on a service the network still lets through. The link goes in a new `openflux_link` secret, as the server's `openflux-link` task prints it. The traffic goes back to the links once one answers its probe again. It serves the proxy port, not `tun`.
