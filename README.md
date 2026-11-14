# dotdash

Gets devices in a restricted network out to the open internet through a
server of yours outside it, as [morzer](https://github.com/morzecrew/morzer)
bundles released together from one tag.

**Documentation: <https://morzecrew.github.io/dotdash/>**

| Bundle | Runs on |
| --- | --- |
| `dotdash-server` | a server outside the network: Xray REALITY in front of a cover site, out through your upstream proxy |
| `dotdash-relay` | a machine inside it, carrying devices on to the servers |
| `dotdash-client` | a Linux machine: a proxy port, the whole machine or a LAN |
| `dotdash-canary` | a machine inside it, alerting when devices can't get through |
| `dotdash-acme-dns` | a machine of its own, for the servers' and relays' wildcard certificates |

[`dotdash-manager`](manager) runs a whole network of them from one roster.

## A server

On a fresh Debian or Ubuntu host, with `example.com` pointing at it and
80/443 open:

```sh
curl -fsSLO https://morzecrew.github.io/dotdash/bootstrap.sh    # Docker, sops, age, morzer
less bootstrap.sh && sudo bash bootstrap.sh
morzer secret recipients generate-recovery-key ~/dotdash-recovery.key   # keep it off the machine
sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-server:stable \
  --domain example.com --recovery-recipient age1…
sudo morzer secret set upstreams    # socks5://user:pass@host:port, one per line
sudo morzer apply
sudo morzer task run client-config --output -- phone
```

Every bundle is `ghcr.io/morzecrew/<bundle>`: `:stable` and `:X.Y.Z` are
releases, signed with the release key; `:main` follows `main`, signed with the
dev key. `init` trusts the key a release ships; `--signing-key` checks even
the first against the repository's `MINISIGN_RELEASE_PUBKEY` variable.

## Development

The bundles live in [`bundles/`](bundles), the manager in
[`manager/`](manager) and the docs in [`pages/`](pages)
(`cd pages && uv run zensical serve`). Check a bundle change with
`morzer release verify ./bundles/<name> --render-check`.

## Licence

MIT — see [LICENSE](LICENSE).
