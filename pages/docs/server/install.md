# Install

You need a domain, a Linux host outside the restricted network, and an upstream proxy. `example.com`
stands for your domain throughout.

1. **DNS:** point the domain at the server:

    ```text
    example.com.  A  <server IP>
    ```

2. **Firewall:** open 80/tcp and 443/tcp in the cloud provider's firewall
   (a VPC firewall rule, on some clouds). Docker's published ports bypass
   ufw and firewalld, so the provider's firewall is the one that counts.
   Allow SSH with keys only.

3. **Host:** install Docker, sops, age and morzer, with
   [`bootstrap.sh`](../index.md#what-every-machine-needs) on Debian or
   Ubuntu.

4. **Recovery key:** it decrypts the backups. Make it, and keep it off the
   machine:

    ```sh
    morzer secret recipients generate-recovery-key ~/dotdash-recovery.key
    ```

    It prints the public half, `age1…`, which the next step takes.

5. **Deploy:**

    ```sh
    sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-server:stable \
      --domain example.com --recovery-recipient age1…
    sudo morzer secret set upstream    # user:pass@host:port
    sudo morzer apply
    ```

    - Add `--set upstream_protocol=http` for an HTTP proxy, or `https` or
      `socks-tls` for one that takes TLS. The default is SOCKS5. For
      a WireGuard or OpenVPN exit instead, see
      [WireGuard or OpenVPN upstream](tunnel-upstream.md).
    - `upstream` is `user:pass@host:port`, or `host:port` with no login. The
      password may contain `:` and `@`; an IPv6 host goes in brackets; no
      `socks5://` prefix. Changing proxy later is one `secret set` and one
      restart.
    - `init` prints the release's signing key and trusts it. To check even
      this first release against the key published with the repository, add
      `--signing-key "$(gh variable get MINISIGN_RELEASE_PUBKEY -R morzecrew/dotdash)"`.

6. **Check:** `apply` succeeds only once Xray reaches the internet through
   the upstream and 443 serves the site with a trusted certificate. Later,
   at any time:

    ```sh
    sudo morzer doctor                        # health, and the failing layer if any
    sudo morzer task run exit-check --output  # the exit sites see
    ```

Next: [connect devices](devices.md).
