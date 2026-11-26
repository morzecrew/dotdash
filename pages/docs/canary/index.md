# Canary

The `dotdash-canary` bundle (`ghcr.io/morzecrew/dotdash-canary`) runs on a
machine inside the network you worry about. It connects to a dotdash server,
or a [relay](../relay/index.md), as a device would, and fails `doctor` when it
can't get through: you hear about a block before your users do. It needs
Docker, sops, age and morzer
([`bootstrap.sh`](../index.md#what-every-machine-needs)), and no open port.

## Install

1. **On the server**, add a `<uuid> canary` line to `vless_clients`, then
   print the canary's setup:

    ```sh
    sudo EDITOR=nano morzer secret edit vless_clients
    sudo morzer task run canary-config --output -- canary
    ```

2. **On the canary machine**, run what that printed: `init`, four secrets,
   `apply`. The recovery recipient can be the server's own.

3. **Alerts:** add a notify target and run `doctor` every 10 minutes:

    ```sh
    sudo morzer notify target add https://hooks.example/morzer
    sudo morzer config set doctor.schedule='*:0/10'
    ```

## What it checks

By default the canary checks REALITY on 443. Profiles add a transport:

| `init` flag | Also checks |
| --- | --- |
| `--profile xhttp` | XHTTP, through the server's cover site |
| `--profile xhttp-reality` | [XHTTP with REALITY](../server/xhttp-reality.md), on its own port |
| `--profile mkcp` | [mKCP](../server/mkcp.md), on its own UDP port |
| `--profile hysteria2` | [Hysteria2](../server/hysteria2.md), on its own UDP port, logging in as the canary's id |

Each check fetches `probe_url` through dotdash, in up to three tries.

To measure rather than check, `measure` runs each transport a number of
times and prints the success rate, timeouts and latency as JSON, then
downloads `download_url` three times through each and adds the median
Mbit/s:

```sh
sudo morzer task run measure --output -- 50
```

A canary that follows the [manager](../manager.md) tells it, before every
fleet publish, whether each transport gets through (`facts`), and the manager
leaves a relay its canaries can't get through out of devices' links.

Getting through takes more than `probe_url`'s fetch. A network's DPI may
freeze a connection to a hosting address abroad after its first 16-20 KB,
leaving it open and silent, and a fetch that small never reaches the mark.
So `facts` then downloads `freeze_url` (64 KB) through each transport. A
download that stops partway, with no byte for 8 seconds, cut, or not done in
40 seconds, twice running, counts the transport as not getting through, and
`facts` gives the bytes it got under `stalled`. A download that gets no byte
at all says nothing about a freeze (`freeze_url`'s own host may be down) and
leaves the transport as `probe_url` found it.

The same goes the other way, for a network that counts what a device sends:
`facts` uploads 64 KB to `freeze_up_url` through each transport. An upload
that gets no answer for 8 seconds, twice running, counts the transport as not
getting through, named under `stalled_up`; one that fails sooner (refused, an
error page) says nothing about a freeze.

Both freeze checks, like `measure`'s downloads, go through the transport they
check, and an `https://` URL's certificate is checked.

A network may also freeze a device that opens more than a few connections to
one address within a fraction of a second, for a couple of minutes. REALITY
with Vision opens one for every connection inside it, so a page's parallel
requests set it off, while a check of one connection at a time never does.
`facts` ends with a burst through REALITY: six connections at once, then one
more. When REALITY got through alone but not after the burst, it counts as not
getting through, with `burst: true`. Being last, it freezes nothing `facts`
still checks, but the server stays out of this canary's reach for a couple of
minutes after; `burst_check=false` skips it.

Set `control_url` to a site this canary's network reaches without dotdash, so the
canary's own outage isn't read as its target burnt:

```sh
sudo morzer config set control_url=https://www.example.net/
```

`facts` also times things, to 10 ms. `latency_ms` gives each transport that
gets through the time its `probe_url` fetch took on a new connection:
this network's leg, the target's, and on to the site. `direct_ms` is
`control_url`'s fetch without dotdash, this network's leg alone. The
manager's [report](../manager.md#where-the-time-goes) sets one against the
other.

When REALITY fails, `facts` says what stops it, from the canary's own network,
as `blocked_by`:

| `blocked_by` | What the canary found |
| --- | --- |
| `freeze` | connections freeze partway (the freeze checks above) |
| `burst` | REALITY gets through alone, not after six connections at once (the burst check above) |
| `ip` | no TCP connection to the server's port at all: a block on its address |
| `sni` | a connection, and REALITY gets through with its hello split: a block on the name by SNI |
| `tls` | a connection, but REALITY fails even split: a block on the TLS, or on REALITY itself |

The manager names it in its verdicts. With `ipv6_url` set to an address
reachable over IPv6 alone, `facts` also fetches it through each transport, as
`ipv6`: whether the server carries devices' IPv6 that way.

`facts` also asks a DNS server (`udp_target`, `1.1.1.1:53`) over UDP through
each transport and gives the result as `udp`: whether the server carries
devices' UDP (`upstream_udp`), which decides what WebRTC shows behind a TUN
([WebRTC](../server/leaks.md#webrtc)).

`facts` also tries REALITY with its ClientHello split into small TLS records,
sent apart, and gives the result as `reality_split`. REALITY failing while
the split one gets through is a box blocking the server's name by SNI,
reassembling TCP but not TLS records, and the manager then
[hands devices the split](../manager.md#a-name-blocked-by-sni).

## Several servers, and relays

A canary watches one server. With [several servers](../server/several-servers.md),
`canary-config` prints how to point a canary at each of the others. To watch a
relay instead, run the commands its `relay-entry` prints on the canary,
without the xhttp profiles: the canary then connects through the relay, as a
phone on that network would. A relay with Hysteria2 of its own prints the
`hysteria2` profile and its port too, and the canary checks it under the
relay's own site's certificate. A canary that follows the
[manager](../manager.md) gets that port from it.

### A relay's CDNs

A canary that follows the manager also checks each CDN in front of the relay
it watches: its [`cdn_hosts`](../server/cdn.md#in-front-of-a-relay) and the
names of a [CDN at its door](../server/cdn.md#a-cdn-that-fetches-in-plain-http),
which the manager hands it with the relay's CDN path. Each goes out through
the CDN as a device's CDN link does, with the same settings, and gets the
checks a transport gets, freeze downloads included. `facts` gives each under
`cdn`, by name, and the manager judges a [CDN-only relay](../server/cdn.md#the-cdns-origin-only)
by these alone. A CDN that the roster gives a `cdn_extra` is not checked: the
canary doesn't carry those settings.

A canary set up by hand checks them once given the same values:

```sh
sudo morzer config set dotdash_cdn_hosts=<cdn= of the relay's line> dotdash_origin_host=<its origin=, or none>
sudo morzer secret set dotdash_cdn_xhttp_path   # the cdnpath= of the relay's line
```

A canary seized on the censored network gives away what a seized phone
behind the same relay does: the CDN names and the CDN path, beside the
relay's address and keys it already holds.

## On a mobile line

Mobile networks can be restricted where wired lines are not, so a canary on
a wired line can't see what phones see. Run one on a small machine with a USB
mobile modem on the network you care about, with mobile data as its only way
out, and point it at a relay. One for each network and region that matters.
A canary that fails there while the relay itself passes `doctor` means the
relay's address no longer gets through for devices.

## Reference

| Parameter | Default | |
| --- | --- | --- |
| `dotdash_server` | none, given at `init` | the server's domain, sent as the TLS server name; a relay's site |
| `dotdash_address` | none, given at `init` | where to connect: normally the same domain; an IP, a CDN's name, or a relay's address |
| `dotdash_port` | `443` | the server's `https_port` |
| `dotdash_xhttp_reality_port` | `8443` | the server's `xhttp_reality_port` |
| `dotdash_kcp_port` | `8447` | the server's `kcp_port` |
| `dotdash_kcp_header` | `dtls` | the server's `kcp_header` |
| `dotdash_kcp_open` | `none` | the server's `kcp_open` |
| `dotdash_hysteria2_port` | `443` | the server's `hysteria2_port`, or a relay's |
| `dotdash_hysteria2_pin` | `none` | the SHA-256 of a certificate Hysteria2 trusts in place of the public CAs, as `openssl x509 -fingerprint -sha256` prints it, for a server whose certificate no public CA signed; `none` checks it as devices do |
| `dotdash_public_key` | none, given at `init` | the REALITY public key, the `pbk` of a link |
| `dotdash_cdn_hosts` | `none` | a relay's `cdn=` names, comma-separated, each checked [through its CDN](#a-relays-cdns) |
| `dotdash_origin_host` | `none` | a relay's `origin=` names, comma-separated `<name>[/<path>]`, each checked through its CDN at the relay's door |
| `probe_url` | `https://www.gstatic.com/generate_204` | what each check fetches through dotdash; any 2xx is healthy |
| `download_url` | `https://speed.cloudflare.com/__down?bytes=1000000` | what `measure` downloads for its Mbit/s, `http://` or `https://`; `none` skips the downloads |
| `control_url` | `none` | a site this canary's network reaches without dotdash, which `facts` fetches directly; `none` for no such check |
| `freeze_url` | `https://speed.cloudflare.com/__down?bytes=65536` | what `facts` downloads through each transport after `probe_url`, past the 16-20 KB a freeze lets through, `http://` or `https://`; `none` skips it |
| `burst_check` | `true` | whether `facts` ends with a burst through REALITY, for a network that freezes a device opening several connections at once; `false` skips it |
| `freeze_up_url` | `https://speed.cloudflare.com/__up` | where `facts` uploads 64 KB through each transport, for a freeze counted on what the device sends, `http://` or `https://`; `none` skips it |
| `udp_target` | `1.1.1.1:53` | a DNS server, `host:port`, that `facts` asks over UDP through each transport, for `udp` |
| `ipv6_url` | `none` | an address reachable over IPv6 alone (an AAAA record only, `http://` or `https://`), which `facts` fetches through each transport, for `ipv6`; `none` for no such check |

| Secret | |
| --- | --- |
| `dotdash_id` | the canary's id, its line in the server's `vless_clients` |
| `dotdash_encryption` | the `encryption=` value of a link |
| `dotdash_short_id` | the `sid=` value of a REALITY link |
| `dotdash_kcp_seed` | the `seed=` value of an mKCP link, for `--profile mkcp` |
| `dotdash_xhttp_path` | the `path=` value of an XHTTP link, without the leading `%2F` |
| `dotdash_cdn_xhttp_path` | the `cdnpath=` value of a relay's line, for its [CDNs](#a-relays-cdns) |

| Task | |
| --- | --- |
| `measure --output -- [count] [url] [timeout]` | each transport `count` times (20 by default), as JSON |
| `facts --output` | what it watches, whether each transport and each CDN in front of a relay gets through (`freeze_url` included), the bytes a stopped download got, and whether `control_url` answers, as JSON; what the manager reads |
