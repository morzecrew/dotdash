# Install

Needs: a domain, a Linux host with Docker ≥ 28 and Compose ≥ 2.35, `sops`,
`age`, morzer ≥ 0.14.0, an upstream proxy. `example.com` is your domain.

1. **DNS:** `example.com  A  <server IP>`.
2. **Firewall:** open 80/tcp and 443/tcp in the cloud provider's firewall
   (on Google Cloud, a VPC firewall rule). Docker's ports bypass ufw and
   firewalld; allow SSH keys only.
3. **Host:** on fresh Debian or Ubuntu, `bootstrap.sh` installs Docker, sops,
   age and morzer, turns on security updates, and sets SSH to keys only:

    ```sh
    curl -fsSLO https://raw.githubusercontent.com/morzecrew/dotdash/main/scripts/bootstrap.sh
    less bootstrap.sh && sudo bash bootstrap.sh
    ```

    Installing morzer by hand: `install.sh --dir /usr/local/bin`. `sudo` and
    morzer's timers do not look in `~/.local/bin`.

4. **Deploy:**

    ```sh
    morzer secret recipients generate-recovery-key ~/dotdash-recovery.key   # keep it off the machine
    sudo morzer init --release oci://ghcr.io/morzecrew/dotdash:stable \
      --require-signature --signing-key "$MINISIGN_RELEASE_PUBKEY" \
      --domain example.com --recovery-recipient age1…
    # add --set upstream_protocol=http and/or --set upstream_tls=true if the proxy needs them
    sudo morzer secret set upstream    # user:pass@host:port
    sudo morzer apply
    ```

    - `MINISIGN_RELEASE_PUBKEY`: `gh variable get MINISIGN_RELEASE_PUBKEY -R morzecrew/dotdash`.
    - `upstream` is `user:pass@host:port`, or `host:port` with no login. The
      password may contain `:` and `@`; an IPv6 host goes in brackets; no
      `socks5://` prefix. Changing proxy is one `secret set`, one restart.
    - `apply` succeeds once Xray reaches the internet through the upstream and
      443 serves the site with a trusted certificate.

Next: [connect devices](clients.md).
