# Releases and CI

[bundle-ci](https://github.com/morzecrew/bundle-ci) builds, signs and
smoke-tests every pull request and push. A push to `main` publishes `:main`;
a `vX.Y.Z` tag publishes all four bundles as `:X.Y.Z` and `:stable`, with a
GitHub release. Each bundle carries signed build provenance:

```sh
gh attestation verify oci://ghcr.io/morzecrew/dotdash:<version> --owner morzecrew
```

A weekly benchmark measures REALITY and XHTTP under added latency and loss;
it informs and never gates. Check a bundle change with
`morzer release verify ./bundle --render-check`.

## Documentation

This site is [Zensical](https://zensical.org) with
[mike](https://github.com/squidfunk/mike) versions on the `gh-pages` branch.
A push to `main` that touches `pages/` publishes `dev`; a `vX.Y.Z` tag
publishes `X.Y` and, for the newest minor, moves `latest` and the root to it.

```sh
cd pages && uv run zensical serve    # http://localhost:8047
```
