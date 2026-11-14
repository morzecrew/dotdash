# dotdash 0.8.0

Nothing to do before updating from 0.7.0, and `morzer rollback` back to it works. From 0.6.x, follow 0.7.0's notes first: the update is refused until `upstreams` is set.

New beside the server: `dotdash-acme-dns`, an acme-dns server of your own for `cert_issuer=acme-dns` ([Certificates](https://morzecrew.github.io/dotdash/latest/server/certificates/#an-acme-dns-server)).

```sh
sudo morzer update --stage
sudo morzer update --to 0.8.0
```

### Added

- The `dotdash-acme-dns` bundle runs your own acme-dns server for `cert_issuer=acme-dns`, installed with morzer like the other bundles. Its `register` task prints each parent domain's CNAME and the `acme_dns` secret for the machines under it.

### Changed

- `morzer rollback` from this release to 0.7.0 works again on the server and the canary, and updates to it may run unattended: only 0.7.0 itself needs its pre-update backup to go back. A canary on 0.6.x is refused the update and set up again from `canary-config`, as for 0.7.0.
