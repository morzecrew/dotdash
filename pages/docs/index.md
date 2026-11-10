# dotdash

dotdash gets devices in a censored network out to the open internet through
a server of yours abroad. It comes as four
[morzer](https://github.com/morzecrew/morzer) bundles, released together from
one tag:

![The four bundles: phones, the client and the canary inside the country reach the dotdash server abroad directly, or through the relay while only domestic addresses get through; the server leaves only through your upstream proxy](assets/diagrams/overview.light.svg#only-light)
![The four bundles: phones, the client and the canary inside the country reach the dotdash server abroad directly, or through the relay while only domestic addresses get through; the server leaves only through your upstream proxy](assets/diagrams/overview.dark.svg#only-dark)

| Bundle | Runs on | What it does |
| --- | --- | --- |
| **[dotdash](server/index.md)** | a server abroad | Xray REALITY on 443 in front of a cover site; everything leaves through your upstream proxy |
| **[dotdash-relay](relay/index.md)** | a machine inside the country | carries phones, clients and canaries on to the server while only domestic addresses get through |
| **[dotdash-client](client/index.md)** | a Linux machine on the client side | a proxy port, the whole machine, or a whole LAN through dotdash |
| **[dotdash-canary](canary/index.md)** | a machine inside the country | connects as a device would, and alerts when it can't get through |

Start with the server: its tasks print the other three's setup. The client
and the canary reach it as phones do, directly or through a relay.

## What every machine needs

Docker ≥ 28 with Compose ≥ 2.35, `sops`, `age`, and morzer ≥ 0.15.0. On a
fresh Debian or Ubuntu machine, `bootstrap.sh` installs them, turns on
security updates, and sets SSH to keys only:

```sh
curl -fsSLO https://morzecrew.github.io/dotdash/bootstrap.sh
less bootstrap.sh && sudo bash bootstrap.sh
```

Installing morzer by hand: `install.sh --dir /usr/local/bin`. `sudo` and
morzer's timers don't look in `~/.local/bin`.

Every bundle ships the key it is signed with: `morzer init` prints it,
trusts it, and requires every later release to be signed by it.

## Releases

| Tag | |
| --- | --- |
| `ghcr.io/morzecrew/<bundle>:stable` | the newest release (`vX.Y.Z` tags), release key |
| `ghcr.io/morzecrew/<bundle>:X.Y.Z` | one release |
| `ghcr.io/morzecrew/<bundle>:main` | every push to `main`, dev key; may be broken |

`<bundle>` is `dotdash`, `dotdash-relay`, `dotdash-client` or
`dotdash-canary`. These docs are versioned with the releases: the version
menu shows each released minor, and `dev` follows `main`.
