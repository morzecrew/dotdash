# Operations

Updates, alerts, backups and `doctor` work the same on
[relay](../relay/operations.md), [client](../client/index.md) and
[canary](../canary/index.md) machines; only the update channel names another
bundle.

| Task | Command |
| --- | --- |
| Update by hand | `sudo morzer update --stage && sudo morzer update --to <version>` |
| New morzer | `sudo morzer self-update` |
| Backups off the machine | `sudo morzer backup target add s3://bucket/dotdash --credentials backup_s3` |
| Alerts | `sudo morzer notify target add https://hooks.example/morzer` |
| Health and faults | `sudo morzer doctor` |
| Which exit sites see | `sudo morzer task run exit-check --output` |
| Metrics for Prometheus | `sudo morzer config set metrics.textfile=/var/lib/prometheus/node-exporter` |

## Unattended updates

From `:stable`, nightly at 03:30.

!!! warning
    This gives whoever holds the release key root on the machine.

```sh
sudo morzer config set update.check=true
sudo morzer config set update.channel=oci://ghcr.io/morzecrew/dotdash-server:stable
sudo morzer config set update.auto_apply=true
```

## Managed from elsewhere

A machine can follow an authority, an operator key that publishes what it
should hold, as
[morzer describes it](https://morzecrew.github.io/morzer/latest/operating/managing-from-elsewhere/).
Each bundle names what an authority may set; everything else stays the
machine's own.

| Bundle | An authority may set | It tells the authority (`facts`) |
| --- | --- | --- |
| server | `vless_clients`, the shared keys (`reality_key`, `vless_seed`, `reality_short_id`, `xhttp_path`, `kcp_seed`, `subscription_key`), `servers`, `relays`, `cdn_hosts`, `pools`, `subscription`, `direct` | its domain and ports, the REALITY public key and the VLESS encryption string |
| relay | `vless_clients`, `dotdash_id`, `dotdash_encryption`, `dotdash_short_id`, `dotdash_servers`, `dotdash_address`, `dotdash_port`, `dotdash_public_key`, `ipv6` | its `relay-entry` line, at [`entry_host`](../relay/reference.md) |
| canary | every `dotdash_*` | nothing |
| client | `subscription_url`, `proxy_password` | nothing |

The upstreams stay each server's own. A relay's facts carry the short id, and
with `own-site` or `mkcp` the XHTTP path or the mKCP seed: the credentials
its devices' links carry anyway. `sudo morzer task run facts --output` prints
them.

## Pin the exit IP

`doctor` fails when the provider moves you:

```sh
sudo morzer config set probe_url=https://api.ipify.org 'probe_expect=^203\.0\.113\.7\s*$'
```

## What the checks say

- **Alerts** cover failed applies, updates and backups, and each morning's
  `doctor`, which names the failing layer: the proxy's address, its
  credentials, the destination, or the exit.
- **`exit-check`:** "IPv6 unavailable" means the upstream has no IPv6 exit,
  which is not a leak. "MISMATCH" means IPv4 and IPv6 leave from different
  networks.
- **Backups** run nightly: secrets, encrypted to the recovery key, and Caddy's
  certificates. See morzer's
  [operating docs](https://github.com/morzecrew/morzer/tree/main/pages/docs/operating).
