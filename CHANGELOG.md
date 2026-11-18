# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- When REALITY fails, a canary's `facts` say what stops it from its own network (`blocked_by`: `ip`, `sni`, `tls` or `freeze`), and `dotdash-manager` names it in its verdicts. With `ipv6_url` set, `facts` also say per transport whether the server carries IPv6 (`ipv6`).

- A canary's `facts` say per transport whether the server carries devices' UDP (`udp`), by asking a DNS server (`udp_target`) over UDP through each. The leaks page says what WebRTC shows in each mode, and how to stop a browser on a proxy port leaking the device's address.

- A canary also tries REALITY with its ClientHello split into TLS records (`reality_split` in its `facts`). When only that gets through, `dotdash-manager` sets the server's `hello_split`, so devices' Xray configs split their REALITY hello past a block on the server's name by SNI.

- `dotdash-manager rotate start`, `swap` and `finish` rotate the servers' REALITY key with no device cut off. The canaries watching servers prove the next key before devices and relays move to it. A canary's `facts` now name the key it checks under.

- The server can accept a second REALITY key beside `reality_key` (`reality_second_key`, with the `reality_key_second` and `reality_short_id_second` secrets), so the key can be rotated with no device cut off. The docs walk through the three steps.

- The server's and the relay's `metrics` profile writes Xray's traffic per inbound and outbound, its upstreams' or servers' verdicts and its heap into the node exporter's textfile directory beside morzer's own metrics, never per device.

- `dotdash-manager report` shows how long each path of each server and relay lasted before it was first blocked, and the median per path. A server or relay in the roster can carry your own `provider` and `address_since`, and the report adds up lifetimes per provider, kept for machines taken out of the roster.

- A relay can reach the servers over XHTTP with REALITY (`dotdash_link=xhttp-reality`), connections reused across devices: about 100 ms sooner to a page's first byte, for about twice the CPU. `relay-config` prints the settings and the `dotdash_xhttp_path` secret when the server runs `xhttp-reality`.

- The canary's `hysteria2` profile checks a server's Hysteria2 beside REALITY, on `dotdash_hysteria2_port` (443), logging in as the canary's own id, in `measure` and `facts` too. A server under `hysteria2` tells `canary-config` and `dotdash-manager` its port, and the manager sets it on the canaries watching that server.

- The server's `hysteria2` profile: Hysteria2 on UDP 443 (`hysteria2_port`), under the site's own certificate, each device's UUID its login. Devices get a `[hy2]` link and an outbound. It runs BBR, or Brutal at `hysteria2_up` Mbit/s for devices that ask.

- A canary's `facts` time each path that gets through (`latency_ms`) and its own network without dotdash (`direct_ms`). `dotdash-manager report` ends with each server's and relay's median per path beside its canaries' network, and what each relay adds over the servers.

- `dotdash-client`'s `dns_server` (`1.1.1.1`): under `tun`, the DNS server asked directly for dotdash's server names, the direct rules and `.lan`, `.local` and `.home.arpa` names. Your router's address answers the LAN's own names.

- An `upstreams` line can put its tags first, `name=isp-a group=ipv6 | socks5://…`, so each name stays at the start of its line however long the URL runs. Lines with the tags after the URL still work, and a line without tags is still just its URL.

- Each device's subscription URL also serves its Xray config, the one `client-config --full` prints, to a request with `Accept: application/json` alone, and at the URL with `.json`: for a client that runs Xray itself. Own-site relays pass it on; a request a CDN passed on gets the site's 404.

- `dotdash-manager report`: how long each server and relay lasted before it first burnt, how often and how long it was burnt, which paths went off and how often a spare stood in, with the relays' median lifetime; relays taken out of the roster stay in it.

- Spare relays: a relay with `spare = true` in `dotdash-manager`'s roster runs and is watched but devices don't get it, until a relay burns; then it stands in for that relay, in its pools, at the next sync, and waits again once the relay is back.

- A canary's `facts` also catch a freeze counted on what the device sends: each transport uploads 64 KB to `freeze_up_url`, and one whose upload gets no answer for 8 seconds twice counts as not getting through, named under `stalled_up`. `freeze_up_url=none` turns it off.

- `dotdash-manager` tells a burnt relay that's blocked from one that's down, by the relay's own hourly fleet row: running means blocked on the way, so replace its address; a row gone quiet or services down means fix the machine first.

- A canary's `facts` catch a connection frozen after its first 16-20 KB: each transport also downloads `freeze_url` (64 KB), and one whose download stops partway twice counts as not getting through, with the bytes it got under `stalled`. `freeze_url=none` turns it off.

- `dotdash-manager` drops just a relay's blocked path when its canaries find one transport cut while another gets through: the relay's line gets `off=reality`, `off=xhttp` or `off=mkcp`, and devices get its other links. A path blocked on every relay is kept and reported.

- A server or relay can share a machine with your own web server on 80 and 443, which passes dotdash's names through untouched. `listen`, `https_port` and `http_port` choose where dotdash publishes, such as spare ports on `127.0.0.1`; the server's `entry_port` keeps links on 443.

### Changed

- The Xray config devices get (`client-config --full`, the subscription's JSON, `dotdash-client`) shares UDP flows over a few connections on REALITY links (XUDP Mux): one connection for 20 flows instead of 20, each later flow answering in one round trip instead of three.

- The DNS tunnel sends every 50 ms (`xdns_tti`), not every 200: about three times the speed. Devices' configs spread its queries over three resolvers (`xdns_resolvers`), so each sees little more than before.

- Hysteria2 no longer answers a stray packet with a stateless reset, which the site's own HTTP/3 never sends and a prober could tell apart.

- Devices' and relays' configs probe each link at a moment of its own (`burstObservatory`), not all together, which tied a device's links to each other for an observer. Picking the fastest works as before.

- Every Xray container sets Go's soft memory limit (`GOMEMLIMIT`) at about 90% of its memory cap, so Go collects garbage harder near the cap instead of the kernel killing Xray.

- The server's gate and a relay send to devices on BBR, in their own containers only (`tcp_congestion`). On a lossy last mile it kept 6-50 times cubic's speed in the lab. Set `tcp_congestion=cubic` on a kernel without `tcp_bbr`, where the apply would otherwise fail and roll back.

- A server that resolves names itself (`resolve=gateway`), and the Xray config `client-config` prints, answer a name looked up before from the cache at once, even after it expired, and ask again in the background, for a day at most. A site revisited no longer waits for a lookup through the upstream.

- `dotdash-client` runs Xray instead of mihomo. It asks the subscription URL for the device's Xray config and uses whichever outbound answers fastest. Update the server first: an older one serves no config, and the client then refuses traffic rather than send it around dotdash.

- `dotdash-client`'s rule parameters keep their form. A line whose type isn't DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-REGEX, GEOSITE, IP-CIDR, IP-CIDR6, GEOIP or DST-PORT stops the change, naming the line. IP rules never look a name up, so `no-resolve` changes nothing.

- The server's and relay's TLS and HTTP ports are published on every IPv4 address (`listen=0.0.0.0`), and no longer on IPv6 too. A domain with an AAAA record reaches dotdash over IPv4 only.

- `dotdash-acme-dns` needs morzer 0.17.1, which backs up a machine set up without a recovery key, so updates there no longer depend on the placeholder secret the bundle carried; the secret is gone.

### Fixed

- `dotdash-client` under `tun` no longer sends traffic around dotdash while Xray is down, after a crash or on the restart for a new subscription. A kill switch keeps routing rules that let only Xray's own connections and the LAN out then, and `doctor` checks them.


## [0.8.0] - 2026-11-15

### Added

- The `dotdash-acme-dns` bundle runs your own acme-dns server for `cert_issuer=acme-dns`, installed with morzer like the other bundles. Its `register` task prints each parent domain's CNAME and the `acme_dns` secret for the machines under it.

### Changed

- `morzer rollback` from this release to 0.7.0 works again on the server and the canary, and updates to it may run unattended: only 0.7.0 itself needs its pre-update backup to go back. A canary on 0.6.x is refused the update and set up again from `canary-config`, as for 0.7.0.

## [0.7.0] - 2026-11-14

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

## [0.6.0] - 2026-11-11

### Added

- CDNs in front of a relay: with the `own-site` profile, the relay's new `cdn_hosts` parameter adds `cdn=<names>` to its line, and devices get an XHTTP link through each CDN, shaped as for the server's `cdn_hosts`. The CDN's account then names a relay rather than the server, and pools take these names too.

- A QUIC-shaped opener in front of mKCP: the new `kcp_open` parameter (`quic`) sends a QUIC-Initial-shaped packet before the flow, on the server, relays and canary; links carry it in `fm=` for v2rayN and v2rayNG. It is a fixed shape, off unless set, and no help where QUIC itself is blocked; measure it on a canary first.

- The canary's `measure` adds throughput: three downloads of the new `download_url` parameter (1 MB from speed.cloudflare.com unless set, `https://` only, `none` to skip) through each transport, with how many completed and the median Mbit/s.

- VLESS over mKCP, an opt-in UDP transport for networks that block the TCP ones: the new `mkcp` profile serves it on `kcp_port` (8447/udp), encrypted under the new `kcp_seed` secret, its packets starting with a fake `kcp_header` (`dtls` unless set). Devices get a `[kcp]` link and outbound per server (v2rayN, v2rayNG).

- mKCP on relays: the relay's `mkcp` profile serves it under its own `kcp_seed`, `relay-entry` adds `kcp=<port>,<header>,<seed>` to its line, and devices get a `[relay <host> kcp]` link and outbound through it. A server from before reads no such field.

- The canary checks mKCP with `--profile mkcp`, with the server's `kcp_port`, `kcp_header` and `kcp_seed`, which `canary-config` prints for a server under the `mkcp` profile; `measure` reports it beside REALITY.

- Pools, so a leaked device no longer gives away every relay and CDN host: the new `pools` parameter lists, per pool, its devices, relay hosts and CDN hosts. A device in a pool gets its pools' entry points and those in no pool; a device in none gets them all, and a member that names nothing is reported.

- XHTTP through a relay with a site of its own: the site routes a secret path, the new `xhttp_path` secret, to the relay's Xray, `relay-entry` adds the path to the relay's line, and `client-config` and the subscriptions add an `[relay … xhttp]` link and outbound. The relay needs morzer 0.15.1.

- A backup proxy for when the upstream fails: `upstream_backup_protocol` with the new `upstream_backup` secret. Connections leave through the upstream while the gate's probes get through it, every 30 s, through the backup while they don't, and return by themselves.

- A relay with a site of its own serves devices their subscriptions inside the restricted network, fetched from the server through its tunnel. `client-config` prints `through the relay <domain>: https://<domain>/<token>` under the server's URL, and `relay-entry` ends such a relay's line with `own-site`.

- Local CDNs, for restricted networks: with their names in the new `cdn_hosts` parameter, `client-config`, the Xray config and the subscriptions add an XHTTP link through each, uploading in `GET` requests with the data in headers, as such CDNs need. The CDN page covers the setup and the risks.

- A relay can serve a site of its own: with a domain pointing at it and the new `own-site` profile, devices send the relay's own name, and a prober meets a real site with a certificate for that name, so the name and the address agree as for any site. `relay-config` offers it first; a borrowed site (`site`) still works.

- The upstream can be a WireGuard exit: `upstream_protocol=wireguard` takes the wg-quick client config in the new `upstream_wireguard` secret, such as a home router's or a VPN provider's, and the gate runs Xray's own WireGuard with no extra privilege. It carries UDP, and IPv6 when the exit has it.

- The upstream can be an OpenVPN exit: `upstream_protocol=openvpn` with the new `openvpn` profile takes the client config in the new `upstream_openvpn` secret, and a new config takes effect when set. Its container drops its default route before OpenVPN starts, so nothing leaves around the tunnel.

- A tunnel's config has a secret of its own, so it is set while the proxy is still the upstream, and the switch never leaves the gate without a working upstream: one `config set` for WireGuard, the profile and then the protocol for OpenVPN.

### Changed

- The server's and relays' sites answer under any name, so a CDN in front works on its defaults: no `Host` header to set at the provider. A CDN that sends its own name as SNI gets the site's certificate rather than a failed handshake.

- Links list XHTTP before REALITY, for each server and each relay, in `client-config` and the subscriptions: an app tends to try the first link, and REALITY over raw TCP is blocked most often.

- Subscriptions are served with `Cache-Control: no-store`, so nothing between the server and a device keeps a copy.

- The server bundle is published as `ghcr.io/morzecrew/dotdash-server`, and `ghcr.io/morzecrew/dotdash` gets no new versions. Switch with `sudo morzer update oci://ghcr.io/morzecrew/dotdash-server:stable`, and point `update.channel` there if set. The product, its paths and data stay `dotdash`.

- The server needs morzer 0.15.1: update morzer before updating dotdash.

- The `upstream` secret is no longer required: an installation whose upstream is a tunnel needs none. With a proxy, the egress health check still fails, naming it, while it is unset.

### Removed

- The `xdns-xhttp-reality` profile, deprecated since 0.5.0: a server still set to it must switch before updating. `xdns,xhttp-reality` deploys the same: `sudo morzer config set installation.profile=xdns,xhttp-reality`.

## [0.5.1] - 2026-11-10

### Deprecated

- The `xdns-xhttp-reality` profile goes in 0.6.0, not in this patch release as 0.5.0 announced: removing it would break a server still set to it. `xdns,xhttp-reality` deploys the same; switch before 0.6.0 with `sudo morzer config set installation.profile=xdns,xhttp-reality`.

### Fixed

- The command `relay-config` prints for the relay machine's last step, `relay-entry`, now includes `--output`; without it morzer ran the task and showed nothing, not the line the `relays` parameter needs.

## [0.5.0] - 2026-11-10

### Added

- Every bundle ships the key it is signed with, so `morzer init` needs no `--signing-key`: it prints the key, trusts it, and requires every later release to be signed by it. `--signing-key` still checks even the first release against the repository's.

- A relay for networks that let only some addresses through: `dotdash-relay`, a new bundle released with dotdash, carries devices from a machine inside that network on to this server over port 443. The `relay-config` task prints its setup; its line in the new `relays` parameter adds a link through it for every device.

- A client for a Linux machine or a network: `dotdash-client`, a new bundle released with dotdash, runs mihomo from one device's subscription URL, refreshed through dotdash, with a SOCKS5 and HTTP proxy port, block and direct rules, and a password once the port is published beyond the machine.

- `dotdash-client`'s `tun` profile sends every connection on the machine through dotdash with no proxy settings, its containers' and IPv6 included, with DNS answered by fake addresses whose names dotdash resolves; nothing gets out around dotdash when it is out of reach.

- Under `tun`, `dotdash-client` can be its LAN's gateway: devices that use it as theirs go through dotdash too. `gateway=true` has `doctor` check that the host forwards the LAN into TUN, naming the two `DOCKER-USER` rules a `FORWARD` policy of `DROP` needs, and `dns_listen` answers the LAN's DNS.

- mihomo connects over REALITY and XHTTP with REALITY: those links now carry `support-x25519mlkem768=true`, without which mihomo leaves out the key share Xray's REALITY requires and fails with "REALITY authentication failed". Other clients pass over the parameter.

### Changed

- Every bundle of this release needs morzer 0.15.0: run `sudo morzer self-update` before updating. An older manager refuses the release and changes nothing.

- The DNS tunnel and XHTTP with REALITY run together as `installation.profile=xdns,xhttp-reality`, two profiles combined.

- `upstream6` is no longer generated as a placeholder: a fresh install has none until the IPv6 proxy is turned on. An existing value is kept.

- Unattended updates apply releases again, and `morzer rollback` works again, both of which 0.4.0 turned off for its own change of the upstream settings. An update from 0.3.x is still refused until the `upstream` secret is set.

- `bootstrap.sh` is served from the documentation site: `curl -fsSLO https://morzecrew.github.io/dotdash/bootstrap.sh`. The documentation itself moved from the README to <https://morzecrew.github.io/dotdash/>, one version per release.

### Deprecated

- The `xdns-xhttp-reality` profile: `xdns,xhttp-reality` deploys the same. It goes in the next release.

### Fixed

- `bootstrap.sh` installs morzer 0.15.0, which the bundles require. It installed 0.13.0, so `init` on a freshly prepared host refused the release until `morzer self-update`.

## [0.4.0] - 2026-11-08

### Changed

- The upstream proxy is one secret, `upstream`, holding `user:pass@host:port`, so changing proxy is one restart; `upstream_host`, `upstream_port`, `upstream_username` and `upstream_password` no longer work. Run `sudo morzer secret set upstream` before updating: an update without it is refused.

- This release is never applied unattended, and `morzer rollback` from it is refused, since 0.3.x could not start without the old settings; the pre-update backup is the way back.

- The IPv6 proxy is the `upstream6` secret in the same form, turned on by `upstream6_protocol` (`socks` or `http`, now `none` by default) instead of `upstream6_host`. With it on, set `upstream6` and `upstream6_protocol` before updating, or IPv6 goes back to the first proxy.

- Links are named after the device and transport, such as `phone [reality]`, `phone [xhttp]` and `phone [xhttp+reality]`, in place of `dotdash-phone`, `dotdash-xhttp-phone` and `dotdash-xhttp-reality-phone`. Apps show the new names once the links are added again, or at the next subscription refresh.

- With subscriptions on, `client-config` prints each device's subscription URL alone, so the output stays short; `--full` before the device's name (`-- --full phone`) adds its links and Xray config, as before. With subscriptions off it prints what it always did.

- The subscription service reports healthy only once every device's subscription is written: an apply or an update waits for it, and `doctor` names the service when that never happens.

## [0.3.0] - 2026-11-08

### Added

- Optional subscriptions (`subscription`): each device gets a URL on the cover site that serves its links, which `client-config` prints and the app refreshes by itself, so a revocation or a key rotation reaches devices without resending links. Rotating `subscription_key` moves every URL.

- An optional second proxy for IPv6 (`upstream6_host`, with its own credentials), for an upstream that leaves over IPv4 only: destinations with an IPv6 address, sites with both included, leave through it, and the rest through the first. Neither falls back to the other, and `doctor` names the one that fails.

### Changed

- The Xray config `client-config` prints checks all its entries at once every 30 seconds, where it checked one a minute in turn, so it leaves an entry that stops answering within about half a minute instead of up to several minutes. That is two small requests a minute per entry.

## [0.2.0] - 2026-11-08

### Added

- The `exit-check` task prints the IPv4 and IPv6 addresses the upstream leaves from, each with its network and country, and says whether IPv6 is unavailable or leaves from another network than IPv4. It changes nothing.

- Every apply and update, and every `doctor`, checks the release's invariants against what runs: traffic leaves through the upstream only, every inbound demands a client, and only the bundle's own ports are published, by unprivileged containers. An update that breaks one is rolled back; drift fails `doctor`.

- An optional third transport: XHTTP under REALITY instead of TLS, on a port of its own (`xhttp_reality_port`, 8443). The `xhttp-reality` profile turns it on, `xdns-xhttp-reality` with the DNS tunnel; `client-config` then prints a third link and outbound, and the first two as before.

- The canary's `measure` task fetches a URL through each transport N times and prints, as JSON, how many succeeded, timed out or failed, and the latency of those that succeeded.

- The canary's `xhttp-reality` profile checks XHTTP with REALITY beside REALITY, on the server's `xhttp_reality_port`.

- Both bundles carry signed build provenance, naming the commit and workflow run that built them. Check it with `gh attestation verify oci://ghcr.io/morzecrew/dotdash:<version> --owner morzecrew`, beside the signature morzer verifies.

- With several servers (`servers`), `canary-config` also prints how to point a canary at each of the others: they share the secrets, so only `server` and `address` change.

- The Xray config `client-config` prints answers the device's DNS, in an app's VPN or TUN mode, over DNS-over-HTTPS (`dns_resolver`) through the tunnel, with IPv4 addresses only: lookups no longer reach the local network's resolver or need the upstream to relay UDP. The README covers each app.

### Changed

- Both bundles need morzer 0.14.0 or later. `sudo morzer secret edit vless_clients` then opens the list as plain text, one client per line, and `init` needs no `--product`.

- When the way out fails, `doctor` says which layer did: the upstream proxy's address, its credentials, the destination behind it, or an exit that no longer matches `healthcheck_expect`. The health checks are now `cover-site` and `egress`.

- Xray's `log_level` defaults to `error`. At `warning` and below it names the destinations of failed connections, which a log should not keep; set it back for debugging.

- `client-config` prints one complete Xray config per device, for one server too: it uses whichever of REALITY and XHTTP answers fastest on any listed server, and the DNS tunnel only when none answers, instead of printing the tunnel's outbound alone.

### Fixed

- The cover site's error answers, such as 404 and 405, no longer name the server, and carry the site's headers like its pages do. A prober could tell them apart.

- The canary's `xhttp` profile applies. Its Compose file found the base file by a path relative to a directory morzer does not run Compose from, so the profile failed validation.

- A failed first apply, of dotdash or the canary, no longer leaves a directory where Xray's rendered configuration goes, which made every later apply fail to render it. A missing configuration file or Caddyfile now stops the container from starting instead.

### Security

- The upstream no longer learns which hostnames clients visit: this server resolves them over DNS-over-HTTPS sent through the upstream (`resolve=gateway`, the default) and hands it addresses only. A name resolving to a private address is blocked; `resolve=upstream` restores the old behaviour.

- Xray has no route out of the machine. It runs on internal networks only, and a small gate container forwards the public port to it and carries its traffic to the upstream, whose credentials only the gate holds. Whatever Xray's own config says, it cannot send traffic past the upstream.

- Caddy no longer writes the XHTTP path, a secret, to its log: it logs errors only, and never the request they concern, so no URI, header or client address either. An XHTTP session cut off mid-response used to log all three.

## [0.1.0] - 2026-11-07

### Added

- A morzer bundle for one Docker host, published as `ghcr.io/morzecrew/dotdash`: releases as `:X.Y.Z` and `:stable`, signed with the release key, and every change to main as `:main`, signed with the dev key. Requires morzer 0.13.0, Docker 28 and Compose 2.35, or later.

- REALITY on port 443: a client holding the key reaches Xray over VLESS with Vision, and anything else reaches a Caddy cover site with a Let's Encrypt certificate. `https_port` moves both to another host port.

- XHTTP over TLS behind one secret path of the cover site, which also works through a CDN that proxies HTTP/2 to the server.

- An optional DNS tunnel on UDP/53, VLESS over mKCP with XDNS, for networks where only DNS gets through. The `xdns` profile turns it on, at install or later; its zone is `t.<domain>` unless `xdns_domain` names another.

- Every inbound uses VLESS Encryption (ML-KEM-768). morzer generates every key, short id and path at install, so no secret is chosen by hand.

- All client traffic leaves through an upstream SOCKS5 or HTTP proxy you provide, optionally over TLS, with no direct fallback. UDP is relayed only through a SOCKS5 upstream that supports it (`upstream_udp`).

- Xray is healthy only while it fetches a URL through the upstream, and `doctor` fails while it cannot. With `healthcheck_expect`, a response that does not match, such as a changed exit IP, fails it too.

- An apply or update succeeds only once port 443 serves the cover site with a certificate a browser trusts.

- The `client-config` task prints each device's REALITY and XHTTP links, and the DNS tunnel's outbound when it is on. With `servers` naming servers that share the keys, it prints links for each and an Xray config that uses whichever answers fastest.

- One VLESS id per device in `vless_clients`: deleting a device's line revokes that device alone.

- The cover site serves your own static files from `site_dir` wherever they have the requested path, and otherwise a bundled page titled with the server's domain.

- `cert_issuer=internal` takes the certificate from Caddy's own CA instead of Let's Encrypt, for a machine the internet cannot reach.

- Unattended updates: the bundle declares that it keeps no database and is safe to roll back, which morzer requires before it installs a release on its own. Nightly backups include Caddy's certificates.

- The `canary-config` task prints the init command and secrets for a dotdash-canary machine acting as one of the clients.

- dotdash-canary, a second bundle released with dotdash as `ghcr.io/morzecrew/dotdash-canary`, for a machine inside a network you care about, such as a box at home. It connects to a dotdash server as an ordinary client and needs no open port.

- The canary's health check fetches `probe_url` through dotdash over REALITY, and with the `xhttp` profile also over XHTTP, in up to three tries. `doctor` fails when all three fail, so a notify target at its default level hears that the network lost its way out.

- Services run as a non-root user in read-only containers with every capability dropped. Xray's access log is always off.

- `scripts/bootstrap.sh` prepares a fresh Debian or Ubuntu server: Docker, sops, age and morzer, unattended security updates, and SSH with keys only once an authorized key exists.
