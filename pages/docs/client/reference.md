# Client reference

## Parameters

Set one with `sudo morzer config set <name>=<value>`; edit a rules parameter
with `sudo morzer config edit <name>`.

| Name | Default | |
| --- | --- | --- |
| `listen` | `127.0.0.1` | the address the proxy port is published on; anything but `127.0.0.1` asks devices for `proxy_user` and `proxy_password` ([sharing](network.md)) |
| `port` | `7890` | the SOCKS5 and HTTP proxy port |
| `proxy_user` | `dotdash` | the username devices give beyond `127.0.0.1` |
| `direct_rules` | a comment | destinations reached around dotdash, one rule per line ([rules](rules.md)) |
| `block_rules` | a comment | destinations refused, one rule per line |
| `subscription_interval` | `3600` | seconds between fetches of the subscription |
| `probe_url` | `https://www.gstatic.com/generate_204` | what picking the fastest link and the health check fetch through dotdash |
| `ipv6` | `allow` | `block`: every IPv6 destination refused before any other rule, a direct rule's included, so apps fall back to IPv4; with `tun` it is still taken in, so nothing leaves around dotdash |
| `gateway` | `false` | under `tun`, this machine is its LAN's gateway, and `doctor` checks the host for it ([gateway](tun.md#a-gateway-for-the-lan)) |
| `dns_listen` | `off` | under `tun`, the address and port that answers the LAN's DNS, such as `192.168.1.10:53` |

Profiles (`installation.profile`): `tun`, the [whole machine](tun.md).

## Secrets

| Name | Generated | |
| --- | --- | --- |
| `subscription_url` | no | the device's subscription URL, as the server's `client-config` prints it |
| `proxy_password` | yes | the password devices give beyond `127.0.0.1` |

## Tasks

| Task | |
| --- | --- |
| `proxy-config --output [-- <address>]` | the proxy URLs and credentials devices need; the address only with `listen=0.0.0.0` |

## Health

`doctor` and each `apply` fetch `probe_url` through dotdash, and with
`gateway=true` check that the host forwards the LAN into TUN.
