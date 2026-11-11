# IPv6 through a second proxy

For an IPv4-only upstream: destinations with an IPv6 address, dual-stack ones
included, leave through the IPv6 proxy, the rest through the first. Neither
falls back to the other.

```sh
sudo morzer secret set upstream6                  # user:pass@host:port, first
sudo morzer config set upstream6_protocol=socks   # or socks-tls, http, https
sudo morzer task run exit-check --output
```

Needs `resolve=gateway` (the default). Two providers show as `MISMATCH` in
`exit-check`, as expected. Off: `sudo morzer config unset upstream6_protocol`.
