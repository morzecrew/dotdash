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
sudo morzer init --release oci://ghcr.io/morzecrew/dotdash:stable \
  --require-signature --signing-key "$MINISIGN_RELEASE_PUBKEY" \
  --domain example.com --recovery-recipient age1…
sudo morzer secret set upstream    # user:pass@host:port
sudo morzer apply
sudo morzer task run client-config --output -- phone
```

`MINISIGN_RELEASE_PUBKEY`: `gh variable get MINISIGN_RELEASE_PUBKEY -R morzecrew/dotdash`.
The full steps, options and operations are in the
[documentation](https://morzecrew.github.io/dotdash/).

| Tag | |
| --- | --- |
| `ghcr.io/morzecrew/dotdash:stable` | releases (`vX.Y.Z` tags), release key |
| `ghcr.io/morzecrew/dotdash:X.Y.Z` | one release |
| `ghcr.io/morzecrew/dotdash:main` | every push to `main`, dev key; may be broken |

## Development

[bundle-ci](https://github.com/morzecrew/bundle-ci) builds, signs and
smoke-tests every pull request; a `vX.Y.Z` tag releases both bundles. Check a
bundle change with `morzer release verify ./bundle --render-check`. The docs
live in [`pages/`](pages): `cd pages && uv run zensical serve`.

## Licence

MIT — see [LICENSE](LICENSE).
