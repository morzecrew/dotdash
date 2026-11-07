# dotdash-canary 0.1.0

### Added

- A morzer bundle for a machine inside a network you care about, such as a box at home, published as `ghcr.io/morzecrew/dotdash-canary` and signed with dotdash's keys. It connects to a dotdash server as an ordinary client and needs no open port. Requires morzer 0.13.0, Docker 28 and Compose 2.35, or later.

- Its health check fetches `probe_url` through dotdash over REALITY, and with the `xhttp` profile also over XHTTP, in up to three tries. `doctor` fails when all three fail, so a notify target at its default level hears that this network lost its way out.

- Its settings come from the dotdash server, whose `canary-config` task prints the init command and secrets for one of its clients.
