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

Each check fetches `probe_url` through dotdash, in up to three tries.

To measure rather than check, `measure` runs each transport a number of
times and prints the success rate, timeouts and latency as JSON, then
downloads `download_url` three times through each and adds the median
Mbit/s:

```sh
sudo morzer task run measure --output -- 50
```

## Several servers, and relays

A canary watches one server. With [several servers](../server/several-servers.md),
`canary-config` prints how to point a canary at each of the others. To watch a
relay instead, run the commands its `relay-entry` prints on the canary,
without the xhttp profiles: the canary then connects through the relay, as a
phone on that network would.

## On a mobile line

Allowlists apply on mobile networks, so a canary on a wired line can't see
what phones see. Run one on a small machine with a USB LTE modem and a SIM
from the operator you care about, with mobile data as its only way out, and
point it at a relay. One for each operator and region that matters.
A canary that fails there while the relay itself passes `doctor` means the
relay's address no longer gets through for devices.

## Reference

| Parameter | Default | |
| --- | --- | --- |
| `server` | none, given at `init` | the server's domain, sent as the TLS server name; a relay's site |
| `address` | none, given at `init` | where to connect: normally the same domain; an IP, a CDN's name, or a relay's address |
| `port` | `443` | the server's `https_port` |
| `xhttp_reality_port` | `8443` | the server's `xhttp_reality_port` |
| `kcp_port` | `8447` | the server's `kcp_port` |
| `kcp_header` | `dtls` | the server's `kcp_header` |
| `reality_public_key` | none, given at `init` | the REALITY public key, the `pbk` of a link |
| `probe_url` | `https://www.gstatic.com/generate_204` | what each check fetches through dotdash; any 2xx is healthy |
| `download_url` | `https://speed.cloudflare.com/__down?bytes=1000000` | what `measure` downloads for its Mbit/s, `https://` only; `none` skips the downloads |

| Secret | |
| --- | --- |
| `vless_id` | the canary's id, its line in the server's `vless_clients` |
| `vless_encryption` | the `encryption=` value of a link |
| `reality_short_id` | the `sid=` value of a REALITY link |
| `kcp_seed` | the `seed=` value of an mKCP link, for `--profile mkcp` |
| `xhttp_path` | the `path=` value of an XHTTP link, without the leading `%2F` |

| Task | |
| --- | --- |
| `measure --output -- [count] [url] [timeout]` | each transport `count` times (20 by default), as JSON |
