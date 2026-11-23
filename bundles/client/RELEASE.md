# dotdash-client 0.14.0

Released with dotdash 0.14.0. Nothing needs doing before updating from 0.13.0, and `morzer rollback` back to it works once the new settings are unset (`sudo morzer config unset proxy_rules geoip geosite`). It needs morzer 0.17.0 or later, as 0.13.0 did.

- **To send a site through dotdash** that a direct rule also matches, such as one site out of a geosite list that otherwise goes around it, add its rule to `proxy_rules`.
- **For rules naming lists Xray's own geodata lacks,** set `geoip` or `geosite` to `<url> <sha256>`. The client fetches the file through dotdash within a minute of starting, keeps it, and restarts on it.

```sh
sudo morzer update --stage
sudo morzer update --to 0.14.0
```

### Added

- dotdash-client's `proxy_rules` send destinations through dotdash even when a direct rule matches them too, such as one site out of a geosite list that otherwise goes around it. Block rules still come first.

- dotdash-client's `geoip` and `geosite` take other geodata, as `<url> <sha256>`, for rules naming lists Xray's own lacks. The client fetches the file through dotdash once it runs, keeps it, and restarts on it.
