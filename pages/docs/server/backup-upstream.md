# A backup proxy

A second proxy for when the upstream fails. Connections leave through the
upstream while it answers, so the exit stays the same, and through the backup
while it doesn't. They go back by themselves once the upstream answers again.

```sh
sudo morzer secret set upstream_backup                  # user:pass@host:port, first
sudo morzer config set upstream_backup_protocol=socks   # or http; upstream_backup_tls=true if needed
```

The gate probes both every 30 seconds, fetching `healthcheck_url` through
each. A failed upstream moves connections within about a minute. Connections
open at that moment break, and apps reconnect. Off:
`sudo morzer config set upstream_backup_protocol=none`.

- **The exit changes** while the backup carries: sites see its address. Pick
  a backup in the same country, so geolocated sites behave the same.
- **`doctor` passes** on the backup, since devices still get out.
  `exit-check` shows which exit is in use. If you [pin the exit IP](operations.md#pin-the-exit-ip),
  match both addresses to stay quiet on the backup, such as
  `'healthcheck_expect=^(203\.0\.113\.7|198\.51\.100\.9)\s*$'`. Match the
  upstream's alone to be told, but then `apply` fails too while the backup
  carries.
- **UDP** goes through the backup only if it is SOCKS5 and `upstream_udp` is
  on, which then holds for both.
- **IPv6** through an [IPv6 proxy](ipv6-upstream.md) has no backup: it
  neither falls back nor is one.
- With a [WireGuard or OpenVPN](tunnel-upstream.md) upstream, the backup is
  still a proxy, so UDP and IPv6 depend on it while it carries.
