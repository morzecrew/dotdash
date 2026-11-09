# dotdash-client 0.5.0

The first release, with dotdash 0.5.0. It needs morzer 0.15.0 or later, which `bootstrap.sh` installs.

### Added

- Every bundle ships the key it is signed with, so `morzer init` needs no `--signing-key`: it prints the key, trusts it, and requires every later release to be signed by it. `--signing-key` still checks even the first release against the repository's.

- A relay for networks that let only domestic addresses through: `dotdash-relay`, a new bundle released with dotdash, carries devices from a machine inside the country on to this server over port 443. The `relay-config` task prints its setup; its line in the new `relays` parameter adds a link through it for every device.

- A client for a Linux machine or a network: `dotdash-client`, a new bundle released with dotdash, runs mihomo from one device's subscription URL, refreshed through dotdash, with a SOCKS5 and HTTP proxy port, block and direct rules, and a password once the port is published beyond the machine.

- `dotdash-client`'s `tun` profile sends every connection on the machine through dotdash with no proxy settings, its containers' and IPv6 included, with DNS answered by fake addresses whose names dotdash resolves; nothing gets out around dotdash when it is out of reach.

- Under `tun`, `dotdash-client` can be its LAN's gateway: devices that use it as theirs go through dotdash too. `gateway=true` has `doctor` check that the host forwards the LAN into TUN, naming the two `DOCKER-USER` rules a `FORWARD` policy of `DROP` needs, and `dns_listen` answers the LAN's DNS.

- mihomo connects over REALITY and XHTTP with REALITY: those links now carry `support-x25519mlkem768=true`, without which mihomo leaves out the key share Xray's REALITY requires and fails with "REALITY authentication failed". Other clients pass over the parameter.

### Changed

- Every bundle of this release needs morzer 0.15.0: run `sudo morzer self-update` before updating. An older manager refuses the release and changes nothing.

- The DNS tunnel and XHTTP with REALITY run together as `installation.profile=xdns,xhttp-reality`, two profiles combined.

- `upstream6` is no longer generated as a placeholder: a fresh install has none until the IPv6 proxy is turned on. An existing value is kept.

- Unattended updates apply releases again, and `morzer rollback` works again, both of which 0.4.0 turned off for its own change of the upstream settings. An update from 0.3.x is still refused until the `upstream` secret is set.

- `bootstrap.sh` is served from the documentation site: `curl -fsSLO https://morzecrew.github.io/dotdash/bootstrap.sh`. The documentation itself moved from the README to <https://morzecrew.github.io/dotdash/>, one version per release.

### Deprecated

- The `xdns-xhttp-reality` profile: `xdns,xhttp-reality` deploys the same. It goes in the next release.

### Fixed

- `bootstrap.sh` installs morzer 0.15.0, which the bundles require. It installed 0.13.0, so `init` on a freshly prepared host refused the release until `morzer self-update`.
