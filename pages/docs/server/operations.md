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
| Whether each CDN is refused subscriptions | `sudo morzer task run cdn-check --output` |
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

## Metrics

With morzer's own metrics in the node exporter's textfile directory
([`metrics.textfile`](https://github.com/morzecrew/morzer/tree/main/pages/docs/operating)),
the `metrics` profile adds Xray's and the gate's's, in the same directory: each one's traffic per inbound and outbound, and the gate's verdicts on its upstreams. Nothing is
counted per device. The exporters run as 65532, so the directory has to be
writable by it:

```sh
sudo setfacl -m u:65532:rwx /var/lib/prometheus/node-exporter
sudo morzer config set metrics_textfile=/var/lib/prometheus/node-exporter   # its default
sudo morzer config set installation.profile=xdns,metrics    # beside the profiles you run
```

| Metric | Labels | Value |
| --- | --- | --- |
| `dotdash_xray_up` | `role` | 1 when the exporter read Xray's counters |
| `dotdash_inbound_bytes_total` | `role`, `inbound`, `direction` | bytes through an inbound since Xray started |
| `dotdash_outbound_bytes_total` | `role`, `outbound`, `direction` | bytes through an outbound since Xray started |
| `dotdash_observatory_alive` | `role`, `outbound` | 1 when the last check got through an upstream |
| `dotdash_observatory_delay_seconds` | `role`, `outbound` | that check's time, while it gets through |
| `dotdash_xray_heap_bytes` | `role` | Xray's Go heap, beside its `GOMEMLIMIT` |

Every series also carries `product`. `rate(dotdash_inbound_bytes_total[5m])`
per inbound shows which transport devices use, and one falling to zero while the others carry on is what a block on it looks like.

## Device traffic

The `device-traffic` profile counts the bytes each device moves through Xray,
for the [manager](../manager.md#leaked-links) to spot a link that may have
leaked. The facts carry the counts by device name to the authority, hourly.
They never carry an address, and the counts go nowhere else: not to the
metrics files.

```sh
sudo morzer config set installation.profile=xdns,device-traffic    # beside the profiles you run
```

To read the counts, the facts task runs in Xray's namespace. It shares
client-config's service, so under this profile client-config's tasks too
reach Xray's internal networks, which have no route out, and start Xray if it
is down. Devices behind a relay reach this server under the relay's id, so
turn the profile on at the relays too.

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
