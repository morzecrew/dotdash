# dotdash

A [morzer](https://github.com/morzecrew/morzer) bundle for one Docker host:
Xray REALITY on 443 in front of a Caddy cover site, an optional DNS tunnel
and XHTTP with REALITY, and all traffic out through your upstream proxy.

- **[Install](get-started/install.md)** a server, then
  **[connect devices](get-started/clients.md)**.
- **[Options](options/cover-site.md)**: your own cover site, a DNS tunnel,
  another port, an IPv6 proxy, a CDN, several servers, a canary.
- **[Operations](operations/index.md)**: updates, alerts, backups, and
  [what leaks where](operations/leaks.md).

## Releases

| Tag | |
| --- | --- |
| `ghcr.io/morzecrew/dotdash:stable` | releases (`vX.Y.Z` tags), release key |
| `ghcr.io/morzecrew/dotdash:X.Y.Z` | one release |
| `ghcr.io/morzecrew/dotdash:main` | every push to `main`, dev key; may be broken |

These docs are versioned with the releases: the version menu shows each
released minor, and `dev` follows `main`.
