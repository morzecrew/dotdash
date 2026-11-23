# dotdash-relay 0.16.0

Released with dotdash 0.16.0. Nothing needs doing before updating from 0.15.0. `morzer rollback` back to it works once the `http-origin` profile is off and `tunnel_host` and `http_origin_*` are unset (`sudo morzer config unset tunnel_host http_origin_port http_origin_from http_origin_host`), and a cover app is back on `dotdash-relay_default`. It needs morzer 0.18.0, as 0.15.0 did.

- **A cover app on this relay** moves to `dotdash-relay_edge`, which it shares with Caddy alone, not with Xray. On `dotdash-relay_default` it keeps working, and `doctor` names it until it moves. A cover app bundle takes the network as its `network` parameter; its `cover` URL stays the same:

    ```sh
    sudo morzer --product <app> config set network=dotdash-relay_edge
    sudo morzer --product <app> apply
    ```

- **A CDN that ends TLS at its own edge** and fetches in plain HTTP can front this relay through the new `http-origin` profile ([CDN](https://morzecrew.github.io/dotdash/server/cdn/#a-cdn-that-fetches-in-plain-http)). Its links need the server at 0.16.0.

```sh
sudo morzer update --stage
sudo morzer update --to 0.16.0
```

### Added

- A relay's `http-origin` profile: a door in plain HTTP on `http_origin_port` for a CDN that ends TLS at its own edge and fetches the origin unencrypted, as some rented for restricted networks do. It answers only the gateway addresses in `http_origin_from`, and only on the CDNs' path, which it passes to Xray's XHTTP inbound. `http_origin_host` reaches the server's line as `origin=`, and devices get a `relay · cdn` link through it uploading 4 KiB at a time. `relay-entry` prints the port and the `xhttpSettings` to give the CDN. The manager carries `origin=` too.

- `tunnel_host` on a relay: one host a cover app may call at `http://caddy:8090`. Caddy sends the calls on as HTTPS inside the link to the servers, or to the relays in `via`, so the relay shows one TLS client, Xray's, where an app calling the host itself showed its own beside it.

### Changed

- **A relay's cover app goes on `dotdash-relay_edge`**, a network of its own with Caddy, as `dotdash_edge` is on a server. On `dotdash-relay_default` it shared Xray's network, where it could reach the subscriptions proxy into the tunnel and the XHTTP inbounds. An app already on `dotdash-relay_default` keeps working, and `doctor` names it until it moves.
