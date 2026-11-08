# dotdash 0.2.0

### Added

- The `exit-check` task prints the IPv4 and IPv6 addresses the upstream leaves from, each with its network and country, and says whether IPv6 is unavailable or leaves from another network than IPv4. It changes nothing.

- Every apply and update, and every `doctor`, checks the release's invariants against what runs: traffic leaves through the upstream only, every inbound demands a client, and only the bundle's own ports are published, by unprivileged containers. An update that breaks one is rolled back; drift fails `doctor`.

- An optional third transport: XHTTP under REALITY instead of TLS, on a port of its own (`xhttp_reality_port`, 8443). The `xhttp-reality` profile turns it on, `xdns-xhttp-reality` with the DNS tunnel; `client-config` then prints a third link and outbound, and the first two as before.

- The canary's `measure` task fetches a URL through each transport N times and prints, as JSON, how many succeeded, timed out or failed, and the latency of those that succeeded.

- The canary's `xhttp-reality` profile checks XHTTP with REALITY beside REALITY, on the server's `xhttp_reality_port`.

- Both bundles carry signed build provenance, naming the commit and workflow run that built them. Check it with `gh attestation verify oci://ghcr.io/morzecrew/dotdash:<version> --owner morzecrew`, beside the signature morzer verifies.

- With several servers (`servers`), `canary-config` also prints how to point a canary at each of the others: they share the secrets, so only `server` and `address` change.

- The Xray config `client-config` prints answers the device's DNS, in an app's VPN or TUN mode, over DNS-over-HTTPS (`dns_resolver`) through the tunnel, with IPv4 addresses only: lookups no longer reach the local network's resolver or need the upstream to relay UDP. The README covers each app.

### Changed

- Both bundles need morzer 0.14.0 or later. `sudo morzer secret edit vless_clients` then opens the list as plain text, one client per line, and `init` needs no `--product`.

- When the way out fails, `doctor` says which layer did: the upstream proxy's address, its credentials, the destination behind it, or an exit that no longer matches `healthcheck_expect`. The health checks are now `cover-site` and `egress`.

- Xray's `log_level` defaults to `error`. At `warning` and below it names the destinations of failed connections, which a log should not keep; set it back for debugging.

- `client-config` prints one complete Xray config per device, for one server too: it uses whichever of REALITY and XHTTP answers fastest on any listed server, and the DNS tunnel only when none answers, instead of printing the tunnel's outbound alone.

### Fixed

- The cover site's error answers, such as 404 and 405, no longer name the server, and carry the site's headers like its pages do. A prober could tell them apart.

- The canary's `xhttp` profile applies. Its Compose file found the base file by a path relative to a directory morzer does not run Compose from, so the profile failed validation.

- A failed first apply, of dotdash or the canary, no longer leaves a directory where Xray's rendered configuration goes, which made every later apply fail to render it. A missing configuration file or Caddyfile now stops the container from starting instead.

### Security

- The upstream no longer learns which hostnames clients visit: this server resolves them over DNS-over-HTTPS sent through the upstream (`resolve=gateway`, the default) and hands it addresses only. A name resolving to a private address is blocked; `resolve=upstream` restores the old behaviour.

- Xray has no route out of the machine. It runs on internal networks only, and a small gate container forwards the public port to it and carries its traffic to the upstream, whose credentials only the gate holds. Whatever Xray's own config says, it cannot send traffic past the upstream.

- Caddy no longer writes the XHTTP path, a secret, to its log: it logs errors only, and never the request they concern, so no URI, header or client address either. An XHTTP session cut off mid-response used to log all three.
