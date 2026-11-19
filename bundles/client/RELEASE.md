# dotdash-client 0.9.0

Released with dotdash 0.9.0. The client runs Xray instead of mihomo and asks the subscription URL for the device's Xray config, which only a 0.9.0 server serves: update the server first, or the client refuses traffic rather than send it around dotdash. Your rule parameters keep their form, and `morzer rollback` back to 0.8.0 works.

```sh
sudo morzer update --stage
sudo morzer update --to 0.9.0
```

### Added

- An `upstreams` proxy line tagged `warm=<n>` keeps `n` connections to its proxy open and logged in (the `warm` profile), so a new connection skips the proxy's handshake. From a server 34 ms from its proxy, a fetch's first byte came after 51 ms instead of 203 ms.

- An app on Apple's network stack, by its User-Agent, gets the subscription's links with Safari's TLS hello (`fp=safari`), as its platform sends; every other app keeps Chrome's.

- When REALITY fails, a canary's `facts` say what stops it from its own network (`blocked_by`: `ip`, `sni`, `tls` or `freeze`), and `dotdash-manager` names it in its verdicts. With `ipv6_url` set, `facts` also say per transport whether the server carries IPv6 (`ipv6`).

- A canary's `facts` say per transport whether the server carries devices' UDP (`udp`), by asking a DNS server (`udp_target`) over UDP through each. The leaks page says what WebRTC shows in each mode, and how to stop a browser on a proxy port leaking the device's address.

- A canary also tries REALITY with its ClientHello split into TLS records (`reality_split` in its `facts`). When only that gets through, `dotdash-manager` sets the server's `hello_split`, or puts `split` on a relay's line, so devices' Xray configs split their REALITY hello past a block on the name by SNI.

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

- The server's gate, the relay and the `warm` container probe each connection's path MTU and hold at most 128 KiB unsent per connection. A path that silently drops large packets no longer stalls every TCP link (Vision's first byte 332 ms instead of never), and a click waits less behind a download on XHTTP.

- Every TCP link in a device's Xray config, and the relay's link to its server, gives up a connection after 15 s of unacknowledged data and redials. When a censor freezes a connection, XHTTP answers again after 17 s instead of a minute.

- A Hysteria2 connection a network froze is given up after 15 s of silence instead of 30, and the device reconnects: it answers again after 16 s instead of 31. The Xray config devices get sends keepalives, so a healthy connection idle that long stays open.

- The gate times out an upstreams line's probe after 1.5 s (Xray's burst observatory) rather than 5. A line throttled hard but still answering, which added a second to every connection, now counts as down and the next one carries the traffic.

- When no upstreams line answers its probe, the gate sends connections through the first line instead of failing them, so a wrong verdict, or a single line that is only slow, no longer stops the traffic. Nothing leaves directly.

- Every apply, update and `doctor` refuses `upstream_udp=true` while an upstreams line is an HTTP or HTTPS proxy, which drops UDP. The policy check also reads a line's `group=` and kind when `name=` and `group=` come before its URL.

- The Xray config devices get (`client-config --full`, the subscription's JSON, `dotdash-client`) shares UDP flows over a few connections on REALITY links (XUDP Mux): one connection for 20 flows instead of 20, each later flow answering in one round trip instead of three.

- The DNS tunnel sends every 50 ms (`xdns_tti`), not every 200: about three times the speed. Devices' configs spread its queries over three resolvers (`xdns_resolvers`), so each sees little more than before.

- Hysteria2 no longer answers a stray packet with a stateless reset, which the site's own HTTP/3 never sends and a prober could tell apart.

- Devices' and relays' configs probe each link at a moment of its own (`burstObservatory`), not all together, which tied a device's links to each other for an observer. Picking the fastest works as before.

- Every Xray container sets Go's soft memory limit (`GOMEMLIMIT`) at about 90% of its memory cap, so Go collects garbage harder near the cap instead of the kernel killing Xray.

- The server's gate and a relay send to devices on BBR, in their own containers only (`tcp_congestion`). On a lossy last mile it kept 6-50 times cubic's speed in the lab. Set `tcp_congestion=cubic` on a kernel without `tcp_bbr`, where the apply would otherwise fail and roll back.

- A server that resolves names itself (`resolve=gateway`), and the Xray config `client-config` prints, answer a name looked up before from the cache at once, even after it expired, and ask again in the background, for a day at most. A site revisited no longer waits for a lookup through the upstream.

- `dotdash-client` runs Xray instead of mihomo. It asks the subscription URL for the device's Xray config and uses whichever outbound answers fastest. Update the server first: an older one serves no config, and the client then refuses traffic rather than send it around dotdash.

- `dotdash-client`'s rule parameters keep their form. A line whose type isn't DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-REGEX, GEOSITE, IP-CIDR, IP-CIDR6, GEOIP or DST-PORT stops the change, naming the line. IP rules never look a name up, so `no-resolve` changes nothing.

- The server and the relay need morzer 0.18.0. Before an apply starts them, it checks each port they publish on that port's own address and protocol, the UDP ports of the DNS tunnel, mKCP and Hysteria2 included, and refuses to start with one taken, naming it, rather than failing after the old containers stopped.

- `dotdash-acme-dns` needs morzer 0.17.1, which backs up a machine set up without a recovery key, so updates there no longer depend on the placeholder secret the bundle carried; the secret is gone.

### Fixed

- `dotdash-client` under `tun` no longer sends traffic around dotdash while Xray is down, after a crash or on the restart for a new subscription. A kill switch keeps routing rules that let only Xray's own connections and the LAN out then, and `doctor` checks them.
