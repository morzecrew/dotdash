#!/bin/sh
# Prints what a client needs. The output is credentials: anyone holding it can
# use this server, so send it only over a channel you would send a password on.
set -eu

uuid=$(cat /run/secrets/vless_uuid)
enc=$(cat /run/secrets/vless_encryption)
path=$(cat /run/secrets/xhttp_path)
: "${DOMAIN:?}" "${XDNS_DOMAIN:?}"

cat <<EOF
== XHTTP through Cloudflare (v2rayN, v2rayNG, Hiddify, Happ, Streisand) ==
vless://${uuid}@${DOMAIN}:443?encryption=${enc}&security=tls&sni=${DOMAIN}&host=${DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#dotdash-cdn

== XDNS tunnel, Xray client outbound (slow; for networks where only DNS works) ==
Replace the resolver with one the network allows; DoH ("https://...") or "tcp://" also work.
"address" must be an IP; XDNS sends through the resolvers, not to it.
{
  "tag": "dotdash-xdns",
  "protocol": "vless",
  "settings": {"address": "1.1.1.1", "port": 53, "id": "${uuid}", "encryption": "${enc}"},
  "streamSettings": {
    "network": "kcp",
    "kcpSettings": {"mtu": 130, "tti": 200},
    "finalmask": {"udp": [{"type": "xdns", "settings": {
      "domains": [{"names": ["${XDNS_DOMAIN}"], "edns0": 1232}],
      "resolvers": [{"addrs": ["udp://1.1.1.1:53"]}]
    }}]}
  }
}

UDP is dropped unless the upstream is SOCKS5 with upstream_udp=true: point the
client's DNS at DoH or TCP so lookups ride the tunnel.
EOF
