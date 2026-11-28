# dotdash

dotdash gets devices in a restricted network out to the open internet through
servers of yours outside it. It is a set of
[morzer](https://github.com/morzecrew/morzer) bundles, released together from
one tag, and a manager that runs a whole network of them from one roster.

**Documentation: <https://morzecrew.github.io/dotdash/>**

## How it works

A device connects to a server outside the network with
[Xray](https://github.com/XTLS/Xray-core), over transports built to look like
ordinary web traffic: VLESS with REALITY on port 443, XHTTP through the
server's own site, and Hysteria2, mKCP and a DNS tunnel for networks that
block the rest. The server's site is a real web app, a stock open-source one
of your choice, so whoever opens it finds what any install of that app shows.
Connections leave the server through the upstreams you choose, usually a
proxy elsewhere, and stop when none of them answers rather than going out
some other way.

Where only some addresses get through, devices reach the servers through a
relay inside the network, or through a CDN in front of a relay or a server.
One relay can carry the devices of several server groups, each to its own
servers and exit. Canaries inside the network connect as devices do, and
report when a way in stops working.

## The bundles

| Bundle | Runs on | What it does |
| --- | --- | --- |
| [`dotdash-server`](https://morzecrew.github.io/dotdash/latest/server/) | a server outside the restricted network | Xray in front of a cover site; devices' links and subscriptions; everything out through your upstream proxy |
| [`dotdash-relay`](https://morzecrew.github.io/dotdash/latest/relay/) | a machine inside it | carries devices on to their own server group while only some addresses get through |
| [`dotdash-client`](https://morzecrew.github.io/dotdash/latest/client/) | a Linux machine | a proxy port, the whole machine, or a whole LAN through dotdash, with a kill switch |
| [`dotdash-canary`](https://morzecrew.github.io/dotdash/latest/canary/) | a machine inside it | connects as a device would, and alerts when it can't get through |
| [`dotdash-acme-dns`](https://morzecrew.github.io/dotdash/latest/acme-dns/) | a small machine of its own | answers the DNS checks of the servers' and relays' wildcard certificates |

[`dotdash-manager`](https://morzecrew.github.io/dotdash/latest/manager/) runs
them all from one roster: it makes each group's keys, hands each machine what
it should hold through morzer's signed desired state, and reads back what each
reports. It never logs in to a machine.

## Where to start

- [Overview and what every machine needs](https://morzecrew.github.io/dotdash/latest/)
- [A server](https://morzecrew.github.io/dotdash/latest/server/install/), then
  its [devices](https://morzecrew.github.io/dotdash/latest/server/devices/)
- [Keep more than one way in](https://morzecrew.github.io/dotdash/latest/ways-in/):
  relays, canaries and CDNs, set up before restrictions start
- [What a device can still leak](https://morzecrew.github.io/dotdash/latest/server/leaks/)
- [Releases and changelog](https://morzecrew.github.io/dotdash/latest/reference/releases/)

## Releases

Every bundle is `ghcr.io/morzecrew/<bundle>`: `:stable` and `:X.Y.Z` are
releases, signed with the release key; `:main` follows `main`, signed with the
dev key. `morzer init` trusts the key a release ships; `--signing-key <key>`
checks even the first release against one of these minisign public keys:

| Key | Public key |
| --- | --- |
| release | `RWSodSvG4wmCA2FCL20MQ43y0Tw+/bcMnej3bzmFYr/yXmSKUx3YdF/B` |
| dev | `RWQAQKYQdRbOZq2c9JoqAoq1mSvGmnVih04GY8vLgxd3cg5eXlgvDlcg` |

## Licence

MIT — see [LICENSE](LICENSE).
