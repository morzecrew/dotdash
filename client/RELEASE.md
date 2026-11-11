# dotdash-client 0.6.0

Released with dotdash 0.6.0, with no changes of its own. It needs morzer 0.15.0 or later, as before:

```sh
sudo morzer update --stage
sudo morzer update --to 0.6.0
```

A 0.6.0 server's subscription may carry mKCP links, which mihomo cannot use: it reads them as TCP, and its url-test passes over them.

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

- A relay with a site of its own serves devices their subscriptions inside the country, fetched from the server through its tunnel. `client-config` prints `through the relay <domain>: https://<domain>/<token>` under the server's URL, and `relay-entry` ends such a relay's line with `own-site`.

- Domestic CDNs, for allowlists: with their names in the new `cdn_hosts` parameter, `client-config`, the Xray config and the subscriptions add an XHTTP link through each, uploading in `GET` requests with the data in headers, as such CDNs need. The CDN page covers the setup and the risks.

- A relay can serve a site of its own: with a domain pointing at it and the new `own-site` profile, devices send the relay's own name, and a prober meets a real site with a certificate for that name, so the name and the address agree as for any site. `relay-config` offers it first; a borrowed site (`site`) still works.

- The upstream can be a WireGuard exit: `upstream_protocol=wireguard` takes the wg-quick client config in the new `upstream_wireguard` secret, such as a home router's or a VPN provider's, and the gate runs Xray's own WireGuard with no extra privilege. It carries UDP, and IPv6 when the exit has it.

- The upstream can be an OpenVPN exit: `upstream_protocol=openvpn` with the new `openvpn` profile takes the client config in the new `upstream_openvpn` secret, and a new config takes effect when set. Its container drops its default route before OpenVPN starts, so nothing leaves around the tunnel.

- A tunnel's config has a secret of its own, so it is set while the proxy is still the upstream, and the switch never leaves the gate without a working upstream: one `config set` for WireGuard, the profile and then the protocol for OpenVPN.

### Changed

- Links list XHTTP before REALITY, for each server and each relay, in `client-config` and the subscriptions: an app tends to try the first link, and REALITY over raw TCP is blocked most often.

- Subscriptions are served with `Cache-Control: no-store`, so nothing between the server and a device keeps a copy.

- The server bundle is published as `ghcr.io/morzecrew/dotdash-server`, and `ghcr.io/morzecrew/dotdash` gets no new versions. Switch with `sudo morzer update oci://ghcr.io/morzecrew/dotdash-server:stable`, and point `update.channel` there if set. The product, its paths and data stay `dotdash`.

- The server needs morzer 0.15.1: update morzer before updating dotdash.

- The `upstream` secret is no longer required: an installation whose upstream is a tunnel needs none. With a proxy, the egress health check still fails, naming it, while it is unset.

### Removed

- The `xdns-xhttp-reality` profile, deprecated since 0.5.0: a server still set to it must switch before updating. `xdns,xhttp-reality` deploys the same: `sudo morzer config set installation.profile=xdns,xhttp-reality`.
