# dotdash

A [morzer](https://github.com/morzecrew/morzer) bundle for a censorship-resistant
proxy on one Linux machine running Docker Compose.

```text
client ── HTTPS ──> Cloudflare ── mTLS (AOP) ──> Caddy :443 ── h2c ──> Xray ─┐
  │                                    (cover site on every other path)         ├─> ISP/residential proxy ──> internet
  └── DNS queries ──> any resolver ──> UDP/53 ───────────────────────> Xray ─┘    (SOCKS5 or HTTP; no direct exit)
```

- **XHTTP through Cloudflare**: VLESS + XHTTP on a secret path. Caddy is the only
  TCP entrypoint and serves a static cover site on everything else.
- **XDNS**: VLESS over mKCP hidden in DNS queries (Xray's `finalmask` DNS tunnel),
  for networks where only DNS gets out. Slow, tens of KB/s.
- **Egress**: every connection leaves through the upstream proxy. There is no
  direct outbound, so if the proxy is down, traffic stops instead of leaking the
  server's IP. Private ranges and BitTorrent are blocked; UDP is dropped unless
  the upstream is SOCKS5 with `upstream_udp=true`.

## Security model

- **Origin locked to Cloudflare.** Caddy serves a Cloudflare Origin CA certificate
  and requires the client certificate Cloudflare presents with zone-level
  [Authenticated Origin Pulls](https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull/),
  signed by a CA only you hold. Anyone else reaching the IP, including other
  Cloudflare accounts, fails the TLS handshake and sees nothing.
- **VLESS Encryption** (ML-KEM-768, post-quantum) on both inbounds, so Cloudflare
  and every DNS resolver on the XDNS path see only ciphertext.
- **Secrets are files**, never environment variables or rendered config: morzer
  keeps them SOPS/age-encrypted at rest and renders them to tmpfs; Xray's image
  resolves `{"$file": ...}` references into its own tmpfs at start.
- **Containers**: non-root (65532), read-only rootfs, all capabilities dropped,
  `no-new-privileges`, memory and PID limits, images pinned by digest. Caddy's
  admin API is off and it keeps no state. Xray sits on an internal network for
  Caddy; only it and the upstream proxy have a route out.
- **Logs**: Xray's access log is off; client addresses are stripped before
  Xray sees a request.

Cloudflare features used (Origin CA, Authenticated Origin Pulls with your own
certificate, gRPC) are available on the free plan.

## Status

The Xray image, `ghcr.io/morzecrew/xray`, is specified in
[platform-images#125](https://github.com/morzecrew/platform-images/issues/125)
and not published yet. Until it is, `bundle/manifest.yaml` pins a placeholder
digest: `release verify` passes, `release build` refuses, and nothing deploys.

## Setting it up

You need: a domain on Cloudflare, a Linux server with a public IP, Docker with
Compose, `sops`, `age`, morzer 0.12.0 or later, and credentials for an ISP or
residential proxy. Below, `example.com` is the proxied name and `t.example.com`
the DNS tunnel's zone.

### 1. Cloudflare

1. **DNS:** `example.com` A record to the server, **proxied** (orange cloud).
2. **SSL/TLS > Overview:** encryption mode **Full (strict)**.
3. **SSL/TLS > Origin Server > Create Certificate:** ECC, covering
   `example.com`, 15 years. Save the certificate and key as `origin.pem` and
   `origin.key`; the key is shown once.
4. **Authenticated Origin Pulls, zone-level:**

   ```sh
   scripts/cf-aop-cert.sh ./aop
   ```

   Upload `aop/aop-client.crt` and `aop/aop-client.key` under
   **SSL/TLS > Origin Server > Authenticated Origin Pulls > Zone-level**, then
   turn Authenticated Origin Pulls on. Do this before the first deployment: the
   origin refuses Cloudflare until Cloudflare presents the certificate. Delete
   the uploaded key afterwards and keep `aop/aop-ca.key` offline (it only signs
   a replacement).
5. **Network:** turn **gRPC** on (XHTTP's `stream-up` mode needs it).

### 2. DNS delegation for the tunnel

```text
ns.example.com.   A    <server IP>       DNS only (grey cloud)
t.example.com.    NS   ns.example.com.
```

The `ns` record publishes the server's IP, which Cloudflare otherwise hides.
With Authenticated Origin Pulls that only reveals a host refusing TLS; to keep
the origin IP private anyway, give the server a second IP for UDP/53 and set
`xdns_bind` to it.

### 3. The server

Open 443/tcp and 53/udp. If `systemd-resolved` holds `127.0.0.53:53`, Docker
cannot publish `0.0.0.0:53`; set `xdns_bind` to the public IP (or turn off
`DNSStubListener`).

Generate the VLESS Encryption key pair once and keep the **ML-KEM-768** block:

```sh
docker run --rm ghcr.io/xtls/xray-core:26.10.31 vlessenc
```

### 4. Install

```sh
morzer secret recipients generate-recovery-key ~/dotdash-recovery.key   # move it off the machine
morzer init --release <bundle> --domain example.com --recovery-recipient age1…
```

`init` asks for anything required it cannot generate. Non-interactively:

```sh
morzer config set upstream_host=proxy.provider.example
morzer config set upstream_port=1080
morzer config set upstream_protocol=socks      # or http
morzer config set xdns_domain=t.example.com

morzer secret set vless_decryption              # the "decryption" value, prompts without echo
morzer secret set vless_encryption              # the "encryption" value
morzer secret set upstream_username
morzer secret set upstream_password
morzer secret set origin_cert < origin.pem
morzer secret set origin_key  < origin.key
morzer secret set cf_aop_ca   < aop/aop-ca.crt

morzer apply
```

`vless_uuid` and `xhttp_path` are generated. `apply` waits until Xray's
healthcheck has fetched a URL through the upstream proxy, then checks that the
origin refuses a TLS client without the AOP certificate.

### 5. Clients

```sh
morzer task run client-config --output
```

Prints a `vless://` share link for XHTTP (v2rayN, v2rayNG, Hiddify, Happ,
Streisand…) and an Xray outbound for XDNS. The output is a credential. The
XDNS outbound sends DNS to `1.1.1.1` by default; use whatever resolver the
network allows, including DoH (`https://…`) or `tcp://`.

## Parameters

| Name | Default | Meaning |
| --- | --- | --- |
| `upstream_protocol` | `socks` | `socks` or `http` |
| `upstream_host`, `upstream_port` | required | the ISP/residential proxy |
| `upstream_udp` | `false` | relay UDP through a SOCKS5 upstream that supports UDP ASSOCIATE |
| `xdns_domain` | required | the delegated tunnel zone |
| `xdns_bind` | `0.0.0.0` | host address UDP/53 is published on |
| `xdns_mtu` | `900` | tunnel reply size; lower it if replies are lost on a resolver path |
| `https_port` | `443` | host port for Caddy |
| `log_level` | `warning` | Xray error log (`debug` … `none`) |
| `healthcheck_url` | `https://www.gstatic.com/generate_204` | fetched through the upstream by the healthcheck |

`morzer status` and `doctor` report the health of both services; Xray is healthy
only while the upstream proxy carries traffic.

## Developing

```sh
morzer release verify ./bundle --render-check
```
