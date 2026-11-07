#!/bin/sh
# Prints what each client needs, or only the client named in $1. The output is
# credentials: anyone holding it can use this server, so send it only over a
# channel you would send a password on.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
want=${1:-}
# A tunnel zone with no dot is a name under the domain, as in the template.
case ${XDNS_DOMAIN:-} in '' | *.*) ;; *) XDNS_DOMAIN=${XDNS_DOMAIN}.${DOMAIN} ;; esac

enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)

client() { # <id> <label>
  cat <<EOF
== $2 ==
REALITY (v2rayN, v2rayNG, Hiddify, Happ, Streisand):
vless://$1@${DOMAIN}:${HTTPS_PORT}?encryption=${enc}&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#dotdash-$2

XHTTP over TLS (for a CDN in front: replace the address with the CDN's name):
vless://$1@${DOMAIN}:${HTTPS_PORT}?encryption=${enc}&security=tls&sni=${DOMAIN}&host=${DOMAIN}&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#dotdash-xhttp-$2

EOF
  [ -n "${XDNS_DOMAIN:-}" ] || return 0
  cat <<EOF
XDNS tunnel, Xray client outbound:
{
  "tag": "dotdash-xdns",
  "protocol": "vless",
  "settings": {"address": "1.1.1.1", "port": 53, "id": "$1", "encryption": "${enc}"},
  "streamSettings": {
    "network": "kcp",
    "kcpSettings": {"mtu": 130, "tti": 200},
    "finalmask": {"udp": [{"type": "xdns", "settings": {
      "domains": [{"names": ["${XDNS_DOMAIN}"], "edns0": 1232}],
      "resolvers": [{"addrs": ["udp://1.1.1.1:53"]}]
    }}]}
  }
}

EOF
}

# One client per line, "<uuid> [name]"; blank lines and "#" comments skipped,
# as the image reads it.
found=
while read -r id name _ || [ -n "${id:-}" ]; do
  case $id in '' | '#'*) continue ;; esac
  [ -z "$want" ] || [ "$want" = "${name:-}" ] || continue
  found=1
  client "$id" "${name:-client}"
done </run/secrets/vless_clients
[ -n "$found" ] || { echo "no client named '$want' in vless_clients" >&2; exit 1; }

[ -n "${XDNS_DOMAIN:-}" ] || exit 0
cat <<EOF
XDNS is slow, for networks where only DNS works. Replace the resolver with one
the network allows; DoH ("https://...") or "tcp://" also work. "address" must
be an IP: XDNS sends through the resolvers, not to it. UDP is dropped unless
the upstream is SOCKS5 with upstream_udp=true, so point the client's DNS at DoH
or TCP and lookups ride the tunnel.
EOF
