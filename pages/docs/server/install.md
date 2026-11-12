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
    sudo morzer secret set upstreams    # socks5://user:pass@host:port, one per line
    sudo morzer apply
    ```

    - `upstreams` lists the ways out, one per line, in order:
      `socks5://`, `socks5+tls://`, `http://` or `https://` and
      `user:pass@host:port`, or a WireGuard or OpenVPN exit's `wireguard://`
      or `openvpn://` line. The first that answers carries the traffic. See
      [Upstreams](upstreams.md) for backups, IPv6, WireGuard and OpenVPN.
    - Changing proxy later is one `secret edit upstreams` and one restart.
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
