# dotdash-client 0.7.0

Released with dotdash 0.7.0. **Before updating**, update morzer: every bundle needs 0.17.0, and an older manager refuses the release and changes nothing. `dns_listen` is off at `none` now, not `off`: if you set it to `off` yourself, unset it first.

```sh
sudo morzer self-update
sudo morzer config unset dns_listen   # only if you set it to off
sudo morzer update --stage
sudo morzer update --to 0.7.0
```

New for the client: `ipv6=block` refuses IPv6 before any rule, and a client machine can follow `dotdash-manager`, which gives it its subscription and proxy password.

### Added

- `cert_issuer=acme-dns` on the server and the own-site relay takes a wildcard certificate over the domain's parent through a DNS-01 check handed to acme-dns by one CNAME (the `acme_dns` secret), keeping the machine's own name out of the certificate logs. Keep servers and relays under separate parents.

- `direct=false` keeps every server's address out of devices' links, configs and subscriptions: devices reach the servers only through relays and CDN hosts, and fetch subscriptions only through own-site relays. `dotdash-manager` sets it on every server from the roster's `direct`.

- A `cdn-check` task on the server tells whether each CDN in front of it and of its relays is refused a subscription, by fetching a decoy one, with no links in it, through each.

- `cover` on the server and the own-site relay puts your own app behind the cover site, by its URL: Caddy passes it every request but a subscription's, XHTTP's and those for your own files, and `doctor` checks that it answers. An app published on a host port is reached as `host.docker.internal`.

- An `ipv6` parameter on the server, the relay and the client: `block` keeps IPv6 out. The client refuses it before any rule, the relay drops it, and the server resolves names to IPv4 only and blocks IPv6 addresses, so dual-stack sites still work over IPv4.

- `upstream_mode` decides how the upstreams share the traffic: `failover`, the first line that answers, then the fastest of the rest; `fastest`; or `balance`, connections spread over every line that answers. `upstream_pin` puts a named line first.

- The `wireguard-line` task turns a WireGuard exit's wg-quick file into its upstreams line, and `openvpn-line` an OpenVPN exit's client config into its own.

- Every bundle names what an authority it follows may set: on a server the devices, the shared keys and the server, relay, CDN and pool lists; on a relay the devices and its way to the servers; on a canary its target; on a client its subscription and proxy password. The rest stays the machine's own.

- A `facts` task on the server and the relay prints, as JSON, what each tells the authority it follows after every change: a server's domain, ports, public key and encryption string, and a relay's `relay-entry` line.

- The canary's `facts` task tells the authority it follows, before every fleet publish, whether each transport gets through to its target, and, with the new `control_url`, whether the canary's own network answers without dotdash.

- `dotdash-manager sync` leaves a relay out of the servers' relays and pools once every canary watching it got through none of its paths three readings in a row, and brings it back when one gets through. It keeps every relay if all would go at once, and only reports a burnt server.

- `dotdash-manager`, installed with uv from the repository's `manager/`, runs a network from one roster: it makes the servers' shared keys, gives every server and relay the same devices, and keeps relays, canaries and client machines pointed at the servers, each machine following it through morzer's desired state.

- `cdn_only` on the relay gives devices its CDN links alone, none to its own address, so a relay can stay the origin of the CDNs in front of it while the relays devices reach directly are blocked. `relay-entry` marks the line `cdn-only`.

- The relay's `entry_host` parameter, the address devices reach it at, which `relay-entry` uses when given none; under `own-site` it is the relay's domain.

- When nothing gets out, `doctor` names each upstreams line it asked by its `name=`: no answer, refused credentials, a WireGuard peer that did not carry it, or an OpenVPN tunnel that is down.

### Changed

- The server and own-site relays answer a subscription request a CDN passed on with the site's 404, so a device's links never pass through a CDN, which could read them. They recognise one by the headers a CDN adds, such as `X-Forwarded-For` and `Via`.

- **Breaking:** `site_dir` is gone from the server and the relay. Your own files are always read from `/srv/dotdash` (the relay's `/srv/dotdash-relay`), which a symlink can point elsewhere, so that one parameter, `cover`, names pages or an app. Move files kept elsewhere before updating.

- **Breaking:** every bundle needs morzer 0.17.0, which health-checks a parameter change, undoes it when the check fails, and waits only on the services the change re-creates. Update morzer first: an older one refuses the release and changes nothing.

- **Breaking:** the server's `healthcheck_url`, `healthcheck6_url` and `healthcheck_expect` are `probe_url`, `probe6_url` and `probe_expect`, as the other bundles name them. An update drops the old values, so set changed ones again after it.

- **Breaking:** every way out is a line of the new `upstreams` secret, in order: `socks5://`, `socks5+tls://`, `http://` or `https://` proxies, `wireguard://` exits and up to 8 `openvpn://` exits. Set it before updating, which is refused until it is: `sudo morzer secret set upstreams`.

- **Breaking:** `ipv6=separate` sends IPv6 destinations through the lines marked `group=ipv6` alone, in place of the IPv6 proxy, and a line may serve both groups. `upstream_udp` now needs every line to carry UDP, tunnels included.

- **Breaking:** the canary names its target as the relay does, `dotdash_server`, `dotdash_address`, `dotdash_port`, `dotdash_public_key`, `dotdash_id`, `dotdash_encryption`, `dotdash_short_id`, and `dotdash_` before the XHTTP and mKCP ones. A canary is not updated to it but set up again from `canary-config`.

- `canary-config` also prints the server's mKCP opener, as `dotdash_kcp_open`.

- **Breaking:** the client's `dns_listen` is off at `none`, as every other parameter says it, rather than `off`.

- `morzer rollback` from this release of the server or the canary is refused, since the earlier release lacks the new names; the pre-update backup is the way back.

- The relay's `cert_issuer` takes effect with `config set`, without a full apply.

- The server, the relay and the canary run Xray 26.11.9, and the client mihomo 1.19.34.

### Removed

- **Breaking:** the `upstream`, `upstream6`, `upstream_backup`, `upstream_wireguard` and `upstream_openvpn` secrets and the `upstream_protocol`, `upstream6_protocol` and `upstream_backup_protocol` parameters with their `*_tls` ones. Their ways out become lines of `upstreams`.

- **Breaking:** the relay's deprecated `dotdash_server`. `dotdash_servers` is now required: on a relay that still has only `dotdash_server`, set `dotdash_servers` before updating.
