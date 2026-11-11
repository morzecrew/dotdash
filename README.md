# dotdash

A [morzer](https://github.com/morzecrew/morzer) bundle for one Docker host:
Xray REALITY on 443 in front of a Caddy cover site, an optional DNS tunnel
and XHTTP with REALITY, and all traffic out through your upstream proxy.

**Documentation: <https://morzecrew.github.io/dotdash/>**

## Quick start

On a fresh Debian or Ubuntu host, with `example.com` pointing at it and
80/443 open:

```sh
curl -fsSLO https://morzecrew.github.io/dotdash/bootstrap.sh    # Docker, sops, age, morzer
less bootstrap.sh && sudo bash bootstrap.sh
morzer secret recipients generate-recovery-key ~/dotdash-recovery.key   # keep it off the machine
sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-server:stable \
  --domain example.com --recovery-recipient age1…
sudo morzer secret set upstream    # user:pass@host:port
sudo morzer apply
sudo morzer task run client-config --output -- phone
```

`init` trusts the signing key the release ships, and every later release must
be signed by it; `--signing-key` checks even the first against the repository's
`MINISIGN_RELEASE_PUBKEY` variable.
The full steps, options and operations are in the
[documentation](https://morzecrew.github.io/dotdash/).

| Tag | |
| --- | --- |
| `ghcr.io/morzecrew/dotdash-server:stable` | releases (`vX.Y.Z` tags), release key |
| `ghcr.io/morzecrew/dotdash-server:X.Y.Z` | one release |
| `ghcr.io/morzecrew/dotdash-server:main` | every push to `main`, dev key; may be broken |

The canary, relay and client bundles, `dotdash-canary`, `dotdash-relay` and
`dotdash-client`, have the same tags.

## Development

[bundle-ci](https://github.com/morzecrew/bundle-ci) builds, signs and
smoke-tests every pull request; a `vX.Y.Z` tag releases all four bundles, which
live in [`bundles/`](bundles): `server`, `relay`, `canary` and `client`. Check a
bundle change with `morzer release verify ./bundles/server --render-check`. The docs
live in [`pages/`](pages): `cd pages && uv run zensical serve`.

## Licence

MIT — see [LICENSE](LICENSE).
