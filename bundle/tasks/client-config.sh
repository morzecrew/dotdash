#!/bin/sh
# Prints what a client needs. The output is credentials: anyone holding it can
# use this server, so send it only over a channel you would send a password on.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"

uuid=$(cat /run/secrets/vless_uuid)
enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)

cat <<EOF
== REALITY (v2rayN, v2rayNG, Hiddify, Happ, Streisand) ==
vless://${uuid}@${DOMAIN}:${HTTPS_PORT}?encryption=${enc}&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#dotdash

== XHTTP over TLS (for a CDN in front: replace the address with the CDN's name) ==
vless://${uuid}@${DOMAIN}:${HTTPS_PORT}?encryption=${enc}&security=tls&sni=${DOMAIN}&host=${DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#dotdash-xhttp
EOF

[ -n "${XDNS_DOMAIN:-}" ] || exit 0

cat <<EOF

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
