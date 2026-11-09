# dotdash-client

Not released yet. The first release comes with the next dotdash release, from
the same tag.

### Added

- A dotdash client for a machine or a network: mihomo with one SOCKS5 and HTTP proxy port that goes out through dotdash over whichever link of the device's subscription answers fastest, refreshing the subscription through dotdash, with rules that refuse destinations or send them directly. Published beyond the machine, the port asks for a password.

- The `tun` profile sends every connection on the machine through dotdash with no proxy settings, its containers' and IPv6 included, with DNS answered by fake addresses whose names dotdash resolves. It runs mihomo as root with `NET_ADMIN` and `DAC_OVERRIDE` on the host's network.

- Under `tun`, the machine can be its LAN's gateway. `gateway=true` has `doctor` check that the host forwards the LAN into TUN, and `dns_listen` answers the LAN's DNS.
