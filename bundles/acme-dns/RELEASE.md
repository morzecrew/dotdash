# dotdash-acme-dns 0.8.0

The first release: an acme-dns server for the wildcard certificates dotdash servers and relays take under `cert_issuer=acme-dns`. Install it on a machine of its own, as [Certificates](https://morzecrew.github.io/dotdash/latest/server/certificates/#an-acme-dns-server) describes.

### Added

- The `dotdash-acme-dns` bundle runs your own acme-dns server for `cert_issuer=acme-dns`, installed with morzer like the other bundles. Its `register` task prints each parent domain's CNAME and the `acme_dns` secret for the machines under it.
