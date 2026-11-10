# DNS tunnel

A fallback for networks that pass little but DNS. The Xray config from
`client-config` switches to it when the other transports fail.

```text
ns.example.com.  A   <server IP>
t.example.com.   NS  ns.example.com.
```

Open 53/udp, then add `--profile xdns` to `init`, or:

```sh
sudo morzer config set installation.profile=xdns
```

If `systemd-resolved` holds port 53, set `xdns_bind` to the public IP.

## A domain of its own

Better: a resolver that flags tunnel queries blocks the domain above them,
which would take the site with it. Use a cheap, unrelated domain
(`example.net`) for nothing but the tunnel:

```text
; at example.net's DNS provider
ns.example.net.  A   <server IP>
t.example.net.   NS  ns.example.net.
```

```sh
dig +short NS t.example.net                       # ns.example.net. once delegated
sudo morzer config set xdns_domain=t.example.net
sudo morzer task run client-config --output -- --full phone   # resend: the config names the zone
```
