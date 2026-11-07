#!/bin/sh
# Prints what each client needs, or only the client named in $1. The output is
# credentials: anyone holding it can use this server, so send it only over a
# channel you would send a password on.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
want=${1:-}
# A tunnel zone with no dot is a name under the domain, as in the template.
case ${XDNS_DOMAIN:-} in '' | *.*) ;; *) XDNS_DOMAIN=${XDNS_DOMAIN}.${DOMAIN} ;; esac
# The servers carrying these clients with the same secrets, in order (the
# servers parameter); self is this one.
servers=$(printf '%s\n' "${SERVERS:-self}" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e "s/^self\$/${DOMAIN}/")
count=$(printf '%s\n' "$servers" | grep -c .)

enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)

links() { # <id> <label> <server>
  cat <<EOF
REALITY via $3 (v2rayN, v2rayNG, Hiddify, Happ, Streisand):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&flow=xtls-rprx-vision&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#dotdash-$2

XHTTP over TLS via $3 (for a CDN in front: replace the address with the CDN's name):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&security=tls&sni=$3&host=$3&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#dotdash-xhttp-$2

EOF
}

outbounds() { # <id>: a REALITY and an XHTTP outbound per server
  n=0
  for s in $servers; do
    n=$((n + 1))
    cat <<EOF
    {"tag": "dotdash-$n-reality", "protocol": "vless",
     "settings": {"address": "$s", "port": ${HTTPS_PORT}, "id": "$1", "encryption": "${enc}", "flow": "xtls-rprx-vision"},
     "streamSettings": {"network": "raw", "security": "reality",
       "realitySettings": {"serverName": "$s", "fingerprint": "chrome", "password": "${pbk}", "shortId": "${sid}"}}},
    {"tag": "dotdash-$n-xhttp", "protocol": "vless",
     "settings": {"address": "$s", "port": ${HTTPS_PORT}, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$s", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/${path}", "host": "$s", "mode": "auto"}}},
EOF
  done | sed '$ s/,$//'
}

client() { # <id> <label>
  echo "== $2 =="
  for s in $servers; do
    if [ "$count" -gt 1 ]; then label="$2-$s"; else label=$2; fi
    links "$1" "$label" "$s"
  done
  if [ "$count" -gt 1 ]; then
    cat <<EOF
Xray client config that moves to another server when one stops answering
(v2rayN, v2rayNG: custom config; local SOCKS on 10808, HTTP on 10809):
{
  "inbounds": [
    {"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}},
    {"listen": "127.0.0.1", "port": 10809, "protocol": "http"}
  ],
  "outbounds": [
$(outbounds "$1")
  ],
  "observatory": {"subjectSelector": ["dotdash-"], "probeUrl": "https://www.gstatic.com/generate_204", "probeInterval": "1m"},
  "routing": {
    "balancers": [{"tag": "dotdash", "selector": ["dotdash-"], "strategy": {"type": "leastPing"}}],
    "rules": [{"type": "field", "network": "tcp,udp", "balancerTag": "dotdash"}]
  }
}

EOF
  fi
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
