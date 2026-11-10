#!/bin/sh
# Prints what each client needs, or only the client named in $1. With
# subscriptions on, that is its subscription URL alone; --full, before the
# name, adds its links and Xray config. The output is credentials: anyone
# holding it can use this server, so send it only over a channel you would
# send a password on.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
full=false
[ "${1:-}" != --full ] || { full=true; shift; }
[ "${SUBSCRIPTION:-false}" = true ] || full=true
want=${1:-}
# A tunnel zone with no dot is a name under the domain, as in the template.
case ${XDNS_DOMAIN:-} in '' | *.*) ;; *) XDNS_DOMAIN=${XDNS_DOMAIN}.${DOMAIN} ;; esac
# The servers carrying these clients with the same secrets, in order (the
# servers parameter); self is this one.
servers=$(printf '%s\n' "${SERVERS:-self}" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e "s/^self\$/${DOMAIN}/")
count=$(printf '%s\n' "$servers" | grep -c .)
# Set by the xhttp-reality profiles' overlay only: XHTTP with REALITY, a third
# link and outbound. Without it the output is what it always was.
xr_port=${XHTTP_REALITY_PORT:-}
# The DoH server the config answers the device's DNS with, through the tunnel.
dns=${DNS_RESOLVER:-https://1.1.1.1/dns-query}

enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
# The dotdash-relay machines in front of this server (the relays parameter),
# one "<host> <site> <public key> <short id> <encryption>" per line; blank
# lines, "#" comments and shorter lines are not relays.
relays=$(printf '%s\n' "${RELAYS:-}" | while read -r h s k i e _; do
  case $h in '' | '#'*) continue ;; esac
  if [ -n "${e:-}" ]; then echo "$h $s $k $i $e"; fi
done)

# The domestic CDNs in front of this server (the cdn_hosts parameter), each
# fronting https://${DOMAIN}.
cdns=$(printf '%s\n' "${CDN_HOSTS:-none}" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e '/^none$/d')
# Their edges take GET alone and no request body (Yandex has answered 413 to
# any since 2026-09-28), so a device uploads in packet-up GETs with the data in
# headers. The server's inbound reads that as it is: its placement is auto. The
# link's extra is the five keys a phone's importer was seen to take, with
# uplinkChunkSize a string; this is it percent-encoded.
cdn_extra='%7B%22scMaxEachPostBytes%22%3A32768%2C%22scMinPostsIntervalMs%22%3A10%2C%22uplinkChunkSize%22%3A%2216384%22%2C%22uplinkDataPlacement%22%3A%22header%22%2C%22uplinkHTTPMethod%22%3A%22GET%22%7D'

# support-x25519mlkem768: mihomo strips the X25519MLKEM768 key share unless a
# link asks for it, and Xray's REALITY refuses a client without it. Other
# clients look up the parameters they know and pass over this one.
links() { # <id> <label> <server>: each named "<label> [<transport>]"
  cat <<EOF
REALITY via $3 (v2rayN, v2rayNG, Hiddify, Happ, Streisand, mihomo):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&flow=xtls-rprx-vision&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&support-x25519mlkem768=true&type=tcp#$2%20%5Breality%5D

XHTTP over TLS via $3 (for a CDN in front: replace the address with the CDN's name):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&security=tls&sni=$3&host=$3&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#$2%20%5Bxhttp%5D

EOF
  [ -n "$xr_port" ] || return 0
  cat <<EOF
XHTTP with REALITY via $3, on port ${xr_port} (v2rayN, v2rayNG, mihomo):
vless://$1@$3:${xr_port}?encryption=${enc}&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&support-x25519mlkem768=true&type=xhttp&path=%2F${path}&mode=auto#$2%20%5Bxhttp%2Breality%5D

EOF
}

# A relay takes REALITY on 443 under its neighbour site's name, with keys of its
# own, and carries the device on to this server as its own client.
relay_links() { # <id> <label>: one per relay, named "<label> [relay <host>]"
  printf '%s\n' "$relays" | while read -r h s k i e; do
    [ -n "$h" ] || continue
    cat <<EOF
REALITY through the relay $h (v2rayN, v2rayNG, Hiddify, Happ, Streisand, mihomo):
vless://$1@$h:443?encryption=$e&flow=xtls-rprx-vision&security=reality&sni=$s&fp=chrome&pbk=$k&sid=$i&support-x25519mlkem768=true&type=tcp#$2%20%5Brelay%20$h%5D

EOF
  done
}

cdn_links() { # <id> <label>: one per CDN, named "<label> [cdn <host>]"
  for h in $cdns; do
    cat <<EOF
XHTTP through the CDN $h (v2rayN, v2rayNG, Happ):
vless://$1@$h:443?encryption=${enc}&security=tls&sni=$h&host=$h&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=packet-up&extra=${cdn_extra}#$2%20%5Bcdn%20$h%5D

EOF
  done
}

cdn_outbounds() { # <id>
  n=0
  for h in $cdns; do
    n=$((n + 1))
    cat <<EOF
    {"tag": "dotdash-cdn-$n", "protocol": "vless",
     "settings": {"address": "$h", "port": 443, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$h", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/${path}", "host": "$h", "mode": "packet-up",
         "uplinkHTTPMethod": "GET", "uplinkDataPlacement": "header", "uplinkChunkSize": 16384,
         "scMaxEachPostBytes": 32768, "scMinPostsIntervalMs": 10}}},
EOF
  done
}

relay_outbounds() { # <id>
  n=0
  printf '%s\n' "$relays" | while read -r h s k i e; do
    [ -n "$h" ] || continue
    n=$((n + 1))
    cat <<EOF
    {"tag": "dotdash-relay-$n", "protocol": "vless",
     "settings": {"address": "$h", "port": 443, "id": "$1", "encryption": "$e", "flow": "xtls-rprx-vision"},
     "streamSettings": {"network": "raw", "security": "reality",
       "realitySettings": {"serverName": "$s", "fingerprint": "chrome", "password": "$k", "shortId": "$i"}}},
EOF
  done
}

outbounds() { # <id>: a REALITY and an XHTTP outbound per server, the third, the relays, the CDNs
  n=0
  { for s in $servers; do
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
    [ -z "$xr_port" ] || cat <<EOF
    {"tag": "dotdash-$n-xhttp-reality", "protocol": "vless",
     "settings": {"address": "$s", "port": ${xr_port}, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "xhttp", "security": "reality",
       "realitySettings": {"serverName": "$s", "fingerprint": "chrome", "password": "${pbk}", "shortId": "${sid}"},
       "xhttpSettings": {"path": "/${path}", "mode": "auto"}}},
EOF
  done; relay_outbounds "$1"; cdn_outbounds "$1"; } | sed '$ s/,$//'
}

xdns_outbound() { # <id>: the DNS tunnel, for the config's last resort
  cat <<EOF
    {"tag": "xdns", "protocol": "vless",
     "settings": {"address": "1.1.1.1", "port": 53, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": 130, "tti": 200},
       "finalmask": {"udp": [{"type": "xdns", "settings": {
         "domains": [{"names": ["${XDNS_DOMAIN}"], "edns0": 1232}],
         "resolvers": [{"addrs": ["udp://1.1.1.1:53"]}]}}]}}}
EOF
}

client() { # <id> <label>
  echo "== $2 =="
  if [ "${SUBSCRIPTION:-false}" = true ]; then
    # As subscription.sh names the device's file.
    token=$(printf '%s:%s' "$(cat /run/secrets/subscription_key)" "$1" | sha256sum | cut -c1-32)
    if [ "${HTTPS_PORT}" = 443 ]; then at=; else at=":${HTTPS_PORT}"; fi
    $full || { printf 'https://%s%s/%s\n\n' "${DOMAIN}" "$at" "$token"; return 0; }
    cat <<EOF
Subscription, for the app to fetch these links from and refresh them after a
revocation or a key rotation (as secret as the links):
https://${DOMAIN}${at}/${token}

EOF
  fi
  for s in $servers; do
    if [ "$count" -gt 1 ]; then label="$2-$s"; else label=$2; fi
    links "$1" "$label" "$s"
  done
  relay_links "$1" "$2"
  cdn_links "$1" "$2"
  if [ "$count" -gt 1 ]; then where=" on any of the servers"; else where=; fi
  if [ -n "$xr_port" ]; then which="REALITY, XHTTP and XHTTP with REALITY"; else which="REALITY and XHTTP"; fi
  [ -z "$relays" ] || which="${which}, or REALITY through a relay,"
  [ -z "$cdns" ] || which="${which}, or XHTTP through a CDN,"
  if [ -n "${XDNS_DOMAIN:-}" ]; then
    last=", and the DNS tunnel only when none answers"
    fallback=', "fallbackTag": "xdns"'
  else
    last='' fallback=''
  fi
  cat <<EOF
Xray client config, for v2rayN or v2rayNG as a custom config (local SOCKS on
10808, HTTP on 10809). It uses whichever of ${which} answers
fastest${where}${last}.
DNS the device sends on port 53, in the app's VPN or TUN mode, is answered
over DoH (${dns}) through the tunnel, with IPv4 addresses only; a
link leaves DNS to the app's own settings:
{
  "dns": {"servers": ["${dns}"], "queryStrategy": "UseIPv4", "disableFallback": true, "tag": "dns"},
  "inbounds": [
    {"listen": "127.0.0.1", "port": 10808, "protocol": "socks", "settings": {"udp": true}},
    {"listen": "127.0.0.1", "port": 10809, "protocol": "http"}
  ],
  "outbounds": [
$(outbounds "$1")$([ -z "${XDNS_DOMAIN:-}" ] || printf ',\n%s' "$(xdns_outbound "$1")"),
    {"tag": "dns-out", "protocol": "dns"}
  ],
  "observatory": {"subjectSelector": ["dotdash-"], "probeUrl": "https://www.gstatic.com/generate_204", "probeInterval": "30s", "enableConcurrency": true},
  "routing": {
    "balancers": [{"tag": "dotdash", "selector": ["dotdash-"], "strategy": {"type": "leastPing"}${fallback}}],
    "rules": [
      {"type": "field", "port": "53", "outboundTag": "dns-out"},
      {"type": "field", "network": "tcp,udp", "balancerTag": "dotdash"}
    ]
  }
}

EOF
}

$full || cat <<EOF
Subscription URLs, one per device, for v2rayN, v2rayNG, Hiddify, Happ or
Streisand to fetch its links from and refresh them; --full prints the links
and the Xray config too.

EOF
# One client per line, "<uuid> [name]"; blank lines and "#" comments skipped,
# as the image reads it. $1 names one client, or gives its uuid.
found=
while read -r id name _ || [ -n "${id:-}" ]; do
  case $id in '' | '#'*) continue ;; esac
  [ -z "$want" ] || [ "$want" = "${name:-}" ] || [ "$want" = "$id" ] || continue
  found=1
  client "$id" "${name:-client}"
done </run/secrets/vless_clients
[ -n "$found" ] || { echo "no client named '$want' in vless_clients" >&2; exit 1; }

$full && [ -n "${XDNS_DOMAIN:-}" ] || exit 0
cat <<EOF
The config's "xdns" outbound, the DNS tunnel, is slow, for networks where only
DNS works. Replace its resolver with one the network allows; DoH
("https://...") or "tcp://" also work. Its "address" must be an IP: XDNS sends
through the resolvers, not to it. UDP is dropped unless the upstream is SOCKS5
with upstream_udp=true, so point the client's DNS at DoH or TCP and lookups
ride the tunnel.
EOF
