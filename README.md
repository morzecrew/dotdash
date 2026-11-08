# dotdash

A [morzer](https://github.com/morzecrew/morzer) bundle for one Docker host:
Xray REALITY on 443 in front of a Caddy cover site, an optional DNS tunnel
and XHTTP with REALITY, and all traffic out through your upstream proxy.

| Tag | |
| --- | --- |
| `ghcr.io/morzecrew/dotdash:stable` | releases (`vX.Y.Z` tags), release key |
| `ghcr.io/morzecrew/dotdash:X.Y.Z` | one release |
| `ghcr.io/morzecrew/dotdash:main` | every push to `main`, dev key; may be broken |

## Install

Needs: a domain, a Linux host with Docker ≥ 28 and Compose ≥ 2.35, `sops`,
`age`, morzer ≥ 0.14.0, an upstream proxy. `example.com` is your domain.

1. **DNS:** `example.com  A  <server IP>`.
2. **Firewall:** open 80/tcp and 443/tcp in the cloud provider's firewall
   (on Google Cloud, a VPC firewall rule). Docker's ports bypass ufw and
   firewalld; allow SSH keys only.
3. **Host:** on fresh Debian or Ubuntu, `bootstrap.sh` installs Docker, sops,
   age and morzer, turns on security updates, and sets SSH to keys only:

   ```sh
   curl -fsSLO https://raw.githubusercontent.com/morzecrew/dotdash/main/scripts/bootstrap.sh
   less bootstrap.sh && sudo bash bootstrap.sh
   ```

   Installing morzer by hand: `install.sh --dir /usr/local/bin`. `sudo` and
   morzer's timers do not look in `~/.local/bin`.
4. **Deploy:**

   ```sh
   morzer secret recipients generate-recovery-key ~/dotdash-recovery.key   # keep it off the machine
   sudo morzer init --release oci://ghcr.io/morzecrew/dotdash:stable \
     --require-signature --signing-key "$MINISIGN_RELEASE_PUBKEY" \
     --domain example.com --recovery-recipient age1…
   # add --set upstream_protocol=http and/or --set upstream_tls=true if the proxy needs them
   sudo morzer secret set upstream    # user:pass@host:port
   sudo morzer apply
   ```

   - `MINISIGN_RELEASE_PUBKEY`: `gh variable get MINISIGN_RELEASE_PUBKEY -R morzecrew/dotdash`.
   - `upstream` is `user:pass@host:port`, or `host:port` with no login. The
     password may contain `:` and `@`; an IPv6 host goes in brackets; no
     `socks5://` prefix. Changing proxy is one `secret set`, one restart.
   - `apply` succeeds once Xray reaches the internet through the upstream and
     443 serves the site with a trusted certificate.

## Clients

```sh
sudo morzer task run client-config --output             # every device
sudo morzer task run client-config --output -- phone    # one
```

Per device: a REALITY link and an XHTTP link (`phone [reality]`,
`phone [xhttp]`), and an Xray config for v2rayN or v2rayNG (custom config)
that uses whichever answers fastest, drops a dead one within about 30 s, and
falls back to the DNS tunnel when it is on. **The output is a password.**

As QR codes in the terminal (`qrencode`):

```sh
sudo morzer task run client-config --output -- phone | grep '^vless://' |
  while read -r link; do qrencode -t ansiutf8 "$link"; done
```

**Devices:** one `<uuid> [name]` line each (`uuidgen` makes an id). Delete a
line to revoke; Xray restarts on save.

```sh
sudo EDITOR=nano morzer secret edit vless_clients
```

A revoked device still knows the shared keys. To hide the server from it too,
`sudo morzer secret rotate reality_key` and `vless_seed`, then resend links.

### Subscriptions

```sh
sudo morzer config set subscription=true
sudo morzer task run client-config --output -- phone           # its URL only
sudo morzer task run client-config --output -- --full phone    # plus links and Xray config
```

- Add the URL as a subscription in the app (v2rayN, v2rayNG, Hiddify, Happ,
  Streisand) and refresh every few hours: revocations and key rotations reach
  devices with nothing to resend.
- A URL is as secret as the links. `sudo morzer secret rotate subscription_key`
  moves every URL; any other path gets the site's 404.

## Options

### Cover site

The bundled page differs between servers only in its title, so one seen
server reveals the others. Give each its own: static files in `/srv/dotdash`
(`site_dir`), readable by uid 65532, served with no restart.

### DNS tunnel

```text
ns.example.com.  A   <server IP>
t.example.com.   NS  ns.example.com.
```

Open 53/udp, then add `--profile xdns` to `init`, or
`sudo morzer config set installation.profile=xdns`. If `systemd-resolved`
holds port 53, set `xdns_bind` to the public IP.

**Better: a domain of its own.** A resolver that flags tunnel queries blocks
the domain above them, which would take the site with it. Use a cheap,
unrelated domain (`example.net`) for nothing but the tunnel:

```text
; at example.net's DNS provider
ns.example.net.  A   <server IP>
t.example.net.   NS  ns.example.net.
```

```sh
dig +short NS t.example.net                       # ns.example.net. once delegated
sudo morzer config set xdns_domain=t.example.net
sudo morzer task run client-config --output -- --full phone   # resend: the config names the zone
```

### XHTTP with REALITY

A third link on its own port (`xhttp_reality_port`, 8443), for a network that
passes another port better than 443. Xray-core clients only (v2rayN, v2rayNG).
Open the port in the provider's firewall, then:

```sh
sudo morzer config set installation.profile=xhttp-reality   # with the DNS tunnel: xdns-xhttp-reality
```

Off: set the previous profile (`xdns`) or `sudo morzer config unset
installation.profile`, before any rollback to a release without it.

### IPv6 through a second proxy

For an IPv4-only upstream: destinations with an IPv6 address, dual-stack ones
included, leave through the IPv6 proxy, the rest through the first. Neither
falls back to the other.

```sh
sudo morzer secret set upstream6                  # user:pass@host:port, first
sudo morzer config set upstream6_protocol=socks   # or http; upstream6_tls=true if needed
sudo morzer task run exit-check --output
```

Needs `resolve=gateway` (the default). Two providers show as `MISMATCH` in
`exit-check`, as expected. Off: `sudo morzer config unset upstream6_protocol`.

### CDN

The XHTTP link works through a CDN that proxies HTTP/2 to
`https://example.com`: put the CDN's name in the link's address. Check its
terms first; Cloudflare's self-serve plans forbid proxies.

Through Cloudflare, ECH also hides `example.com` from the network: the TLS
handshake then shows `cloudflare-ech.com`. Cloudflare turns ECH on by default.
Add it to the XHTTP link, before the `#` (v2rayN ≥ 7.17, v2rayNG ≥ 2.0):

```text
&ech=cloudflare-ech.com%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query
```

In the Xray config, add the same to that outbound's `tlsSettings`:
`"echConfigList": "cloudflare-ech.com+https://1.1.1.1/dns-query"`. With ECH
set, the connection fails rather than falling back to plain SNI.

### Several servers

Same keys on every server, each under its own domain and the same
`https_port`. Links then cover every server, and the Xray config fails over
between them. Add and revoke devices on each.

```sh
# on the first server; sudo on b.example.com must not prompt
for s in vless_clients vless_seed reality_key reality_short_id xhttp_path; do
  sudo cat /run/dotdash/secrets/$s | ssh b.example.com sudo morzer secret set $s
done
# on every server
sudo morzer config set servers=example.com,b.example.com
```

### Canary

A second bundle (`ghcr.io/morzecrew/dotdash-canary`, released with dotdash)
for a machine inside the network you worry about: it connects as a client and
fails `doctor` when it cannot get through. Needs Docker, sops, age and morzer
(`bootstrap.sh`), and no open port.

1. On the server, add a `<uuid> canary` line to `vless_clients`, then run
   what this prints on the canary machine:

   ```sh
   sudo morzer task run canary-config --output -- canary
   ```

2. On the canary machine:

   ```sh
   sudo morzer notify target add https://hooks.example/morzer
   sudo morzer config set doctor.schedule='*:0/10'
   sudo morzer task run measure --output -- 50    # each transport 50 times, as JSON
   ```

Profiles `xhttp` and `xhttp-reality` check those transports too. A canary
watches one server; `canary-config` prints how to point it at the others.

## Operations

| Task | Command |
| --- | --- |
| Update by hand | `sudo morzer update --stage && sudo morzer update --to <version>` |
| New morzer | `sudo morzer self-update` |
| Backups off the machine | `sudo morzer backup target add s3://bucket/dotdash --credentials backup_s3` |
| Alerts | `sudo morzer notify target add https://hooks.example/morzer` |
| Health and faults | `sudo morzer doctor` |
| Which exit sites see | `sudo morzer task run exit-check --output` |
| Metrics for Prometheus | `sudo morzer config set metrics.textfile=/var/lib/prometheus/node-exporter` |

**Unattended updates** from `:stable`, nightly at 03:30. This gives whoever
holds the release key root on the machine:

```sh
sudo morzer config set update.check=true
sudo morzer config set update.channel=oci://ghcr.io/morzecrew/dotdash:stable
sudo morzer config set update.auto_apply=true
```

**Pin the exit IP:** `doctor` fails when the provider moves you.

```sh
sudo morzer config set healthcheck_url=https://api.ipify.org 'healthcheck_expect=^203\.0\.113\.7\s*$'
```

- **Alerts** cover failed applies, updates and backups, and each morning's
  `doctor`, which names the failing layer: the proxy's address, its
  credentials, the destination, or the exit.
- **`exit-check`:** "IPv6 unavailable" means the upstream has no IPv6 exit,
  which is not a leak. "MISMATCH" means IPv4 and IPv6 leave from different
  networks.
- **Backups** run nightly: secrets, encrypted to the recovery key, and Caddy's
  certificates. See morzer's
  [operating docs](https://github.com/morzecrew/morzer/tree/main/pages/docs/operating).

### What leaks where

- Traffic leaves only through the upstream. With the upstream down, clients
  get nothing, never this server's address. Xray has no route out; a gate
  container holds the upstream's credentials. Every apply, update and `doctor`
  checks this against what runs.
- The upstream sees destination addresses, ports and volume, not hostnames:
  this server resolves them over DoH (`dns_resolver`), through the upstream.
  SNI stays visible unless the client uses ECH. `resolve=upstream` hands the
  upstream the hostnames.
- On the device, only the app keeps traffic inside a dropped tunnel (TUN with
  a kill switch, or Android's "block connections without VPN"). A browser IP
  checker showing an IPv6 address that `exit-check` calls unavailable sees the
  device's own: route IPv6 into the tunnel or turn it off in the app.

### DNS on devices

The Xray config from `client-config` answers port-53 DNS over DoH through the
tunnel, IPv4 only, and fails rather than asking the local network. Links leave
DNS to the app. As of November 2026:

- **v2rayNG:** import as a custom config, and keep the SOCKS port at 10808.
- **v2rayN:** TUN with a custom config needs the profile's "Socks port" at
  10808. DNS then follows v2rayN's settings, so keep them on the proxy.
- **Hiddify** drops a config's DNS and routing: use the links. Its own DNS
  goes through the proxy by default.
- **iOS:** Happ runs the config; set "Tunnel DNS" and "Include all networks".
  Check Streisand and V2Box on a DNS leak test site.

### Moving to a new server

Prepare: keep the recovery key off the machine, add a backup target, and set
the `A` record's TTL to 300 s or less. Devices keep their links.

```sh
# on the new server, after bootstrap.sh
sudo morzer --product dotdash installation import --from-backup \
  --target s3://bucket/dotdash --credentials-file ./bucket.yaml \
  --identity ~/dotdash-recovery.key
sudo morzer update oci://ghcr.io/morzecrew/dotdash:stable
# optional, keeps Caddy's certificate (import prints both ids)
sudo morzer backup fetch <backup id>
sudo morzer restore --force --confirm <installation id> --identity ~/dotdash-recovery.key
```

Then point `example.com` (and `ns.example.com`) at the new IP and shut the old
machine down: two live servers with one installation id confuse each other's
backups.

## Parameters

| Name | Default | |
| --- | --- | --- |
| `upstream_protocol` | `socks` | `socks` or `http`; the proxy is the `upstream` secret |
| `upstream_tls` | `false` | TLS to the upstream |
| `upstream_udp` | `false` | relay UDP via a SOCKS5 upstream with UDP ASSOCIATE; otherwise dropped |
| `upstream6_protocol` | `none` | `socks` or `http` turns on the IPv6 proxy, the `upstream6` secret |
| `upstream6_tls` | `false` | TLS to the IPv6 proxy |
| `https_port` | `443` | host port for REALITY and the site |
| `xdns_domain` | `t` | tunnel zone (`xdns`); a name with no dot is under the domain |
| `xdns_bind` | `0.0.0.0` | host address for UDP/53 |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies get lost |
| `xhttp_reality_port` | `8443` | port for XHTTP with REALITY; not `https_port` or 80 |
| `log_level` | `error` | Xray error log; `warning` and below name failed destinations |
| `healthcheck_url` | `https://www.gstatic.com/generate_204` | fetched through the upstream |
| `healthcheck_expect` | `.*` | regex the response must match, such as the exit IP |
| `healthcheck6_url` | `http://api6.ipify.org` | IPv6-only URL fetched through the IPv6 proxy |
| `resolve` | `gateway` | `gateway`: this server resolves over `dns_resolver`; `upstream`: the upstream sees hostnames |
| `dns_resolver` | `https://1.1.1.1/dns-query` | DoH server for `resolve=gateway` and device DNS; `https://` only |
| `subscription` | `false` | a subscription URL per device |
| `cert_issuer` | `acme` | `acme` (Let's Encrypt) or `internal` (offline machines) |
| `site_dir` | `/srv/dotdash` | your own cover site |
| `servers` | `self` | servers sharing these keys, comma-separated |

## CI

[bundle-ci](https://github.com/morzecrew/bundle-ci) builds, signs and
smoke-tests every pull request and push. A push to `main` publishes `:main`;
a `vX.Y.Z` tag publishes both bundles as `:X.Y.Z` and `:stable`, with a GitHub
release. Each bundle carries signed build provenance:

```sh
gh attestation verify oci://ghcr.io/morzecrew/dotdash:<version> --owner morzecrew
```

A weekly benchmark measures REALITY and XHTTP under added latency and loss;
it informs and never gates. Check a bundle change with
`morzer release verify ./bundle --render-check`.
