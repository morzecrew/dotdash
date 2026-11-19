# dotdash-client 0.9.1

Released with dotdash 0.9.1. It needs morzer 0.18.0 and a 0.9.0 or later server, as 0.9.0 did, and `morzer rollback` back to 0.9.0 works.

```sh
sudo morzer update --stage
sudo morzer update --to 0.9.1
```

### Fixed

- `dotdash-client` carries traffic again as soon as the server is back from an outage. When every link failed its last check, traffic now takes the subscription's first link instead of being refused for up to two minutes until the next check. With no links yet, it is still refused.
