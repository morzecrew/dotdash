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
# Set by the mkcp profile's overlay only: VLESS over mKCP, on UDP, a link and
# outbound per server after the others. Its packets are encrypted under the
# seed, then start with the header; a client lists both, in that order, as
# v2rayN and v2rayNG do from a link's seed and headerType.
kcp_port=${KCP_PORT:-}
kcp_header=${KCP_HEADER:-dtls}
kcp_open=${KCP_OPEN:-none}
kcp_seed=
[ -z "$kcp_port" ] || kcp_seed=$(cat /run/secrets/kcp_seed)
# kcp_open=quic: a finalmask noise mask sends a QUIC-Initial-shaped packet
# before the flow. headerType cannot carry it, so such a link gives the whole
# mask list in fm= (url-encoded JSON) in place of seed and headerType, and the
# outbound appends the mask to its list. The packet is a fixed shape; tune it
# on a canary.
# ponytail: a static opener is replayable; a per-device or rotated shape if DPI starts matching it.
kcp_noise='{"type": "noise", "settings": {"noise": [{"type": "hex", "packet": "c300000001088394c8f03e5157080000449e00000002", "delay": "0-0"}]}}'
kcp_masks() { # <seed> <header> [open]: an mKCP outbound's finalmask list
  printf '{"type": "mkcp-legacy", "settings": {"value": "%s"}}' "$1"
  [ "$2" = none ] || printf ', {"type": "mkcp-legacy", "settings": {"header": "%s"}}' "$2"
  [ "${3:-none}" != quic ] || printf ', %s' "$kcp_noise"
}
fm_enc() { # <seed> <header> <open>: the finalmask object, url-encoded for a link's fm=
  printf '{"udp": [%s]}' "$(kcp_masks "$1" "$2" "$3")" | sed \
    -e 's/%/%25/g' -e 's/{/%7B/g' -e 's/}/%7D/g' -e 's/"/%22/g' \
    -e 's/:/%3A/g' -e 's/,/%2C/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g' -e 's/ /%20/g'
}
# The DoH server the config answers the device's DNS with, through the tunnel.
dns=${DNS_RESOLVER:-https://1.1.1.1/dns-query}

enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
# The dotdash-relay machines in front of this server (the relays parameter),
# one "<host> <site> <public key> <short id> <encryption> [own-site [<xhttp
# path>]] [kcp=<port>,<header>,<seed>[,<open>]] [cdn=<host>[,<host>]]" per
# line; blank lines, "#" comments and shorter lines are not relays. own-site:
# the site is the relay's own, which fetches subscriptions from here and, given
# its path, routes XHTTP to the relay's Xray. kcp=: the relay serves mKCP on
# that UDP port too, with the opener <open> (quic) if it names one. cdn=:
# local CDNs front the relay's own site, as cdn_hosts fronts this server's;
# they need its XHTTP path. Each becomes "<host> <site> <key> <sid> <enc>
# <own-site|-> <path|-> <kcp|-> <cdn hosts, comma-separated|->".
all_relays=$(set -f; printf '%s\n' "${RELAYS:-}" | while read -r line; do
  case $line in '' | '#'*) continue ;; esac
  c=- d=- rest=
  for f in $line; do
    case $f in kcp=*) c=${f#kcp=} ;; cdn=*) d=${f#cdn=} ;; *) rest="$rest $f" ;; esac
  done
  # shellcheck disable=SC2086 # one field per word
  set -- $rest
  case $c in - | [0-9]*,[a-z]*,[0-9a-f]* | [0-9]*,[a-z]*,[0-9a-f]*,[a-z]*) ;; *)
    echo "relays: the kcp= field of $1 is not <port>,<header>,<seed>[,<open>]; no mKCP link through it" >&2
    c=- ;;
  esac
  o=${6:-} p=${7:-}
  if [ "$o" != own-site ]; then o='' p=''; fi
  case $d in
    -) ;;
    '' | ,* | *, | *,,* | *[!A-Za-z0-9.,-]*)
      echo "relays: the cdn= field of $1 is not <host>[,<host>]; no CDN link through it" >&2
      d=- ;;
    *) [ -n "$p" ] || {
      echo "relays: $1 names CDNs but no XHTTP path of its own site; no CDN link through it" >&2
      d=-; } ;;
  esac
  if [ -n "${5:-}" ]; then echo "$1 $2 $3 $4 $5 ${o:--} ${p:--} $c $d"; fi
done)

# The local CDNs in front of this server (the cdn_hosts parameter), each
# fronting https://${DOMAIN}.
all_cdns=$(printf '%s\n' "${CDN_HOSTS:-none}" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e '/^none$/d')

# The pools parameter: one "<pool> <member>..." line per pool, the members
# device names, relay hosts and CDN hosts, a relay's own included. A device in
# a pool gets its pools' relays and CDN hosts and those in no pool; a device in
# none gets them all. A relay's CDN hosts go only to devices that get the
# relay. A leaked device then gives away its pools' entry points, not every one.
pools=$(printf '%s\n' "${POOLS:-}" | sed 's/#.*//' | awk 'NF > 1')
has() { # <member> <pool lines>: whether a line lists it
  printf '%s\n' "$2" | awk -v m="$1" '{ for (i = 2; i <= NF; i++) if ($i == m) f = 1 } END { exit !f }'
}
sees() { [ -z "$mine" ] || has "$1" "$mine" || ! has "$1" "$pools"; }
pick() { # <device name>: the relays, CDN hosts and subscription relays it gets
  mine=
  [ -z "$1" ] || mine=$(printf '%s\n' "$pools" | awk -v m="$1" '{ for (i = 2; i <= NF; i++) if ($i == m) { print; next } }')
  relays=$(printf '%s\n' "$all_relays" | while read -r h s k i e o p c d; do
    if [ -z "$h" ] || ! sees "$h"; then continue; fi
    if [ "$d" != - ]; then
      d=$(for x in $(printf '%s' "$d" | tr ',' ' '); do if sees "$x"; then printf '%s,' "$x"; fi; done)
      d=${d%,}
    fi
    echo "$h $s $k $i $e $o $p $c ${d:--}"
  done)
  cdns=$(for h in $all_cdns; do if sees "$h"; then echo "$h"; fi; done)
  # The own-site relays' domains, where a device inside the restricted network
  # fetches its subscription.
  sub_relays=$(printf '%s\n' "$relays" | awk '$6 == "own-site" { print $2 }')
}
# A member that names nothing would leave its device in no pool, or its relay
# or CDN host in none, and so seen by every device: say so.
names=$(awk '$1 !~ /^#/ && NF > 1 { print $2 }' /run/secrets/vless_clients)
relay_names=$(printf '%s\n' "$all_relays" | awk '{ print $1; if ($9 != "-") { gsub(",", "\n", $9); print $9 } }')
for m in $(printf '%s\n' "$pools" | awk '{ $1 = ""; print }'); do
  printf '%s\n%s\n%s\n' "$names" "$all_cdns" "$relay_names" | grep -qxF -- "$m" ||
    echo "pools: $m is no device name, relay host or CDN host" >&2
done
# Their edges take GET alone and no request body (some answer 413 to any),
# so a device uploads in packet-up GETs with the data in headers. The server's
# inbound reads that as it is: its placement is auto. The link's extra is the
# five keys a phone's importer was seen to take, with uplinkChunkSize a string;
# this is it percent-encoded.
cdn_extra='%7B%22scMaxEachPostBytes%22%3A32768%2C%22scMinPostsIntervalMs%22%3A10%2C%22uplinkChunkSize%22%3A%2216384%22%2C%22uplinkDataPlacement%22%3A%22header%22%2C%22uplinkHTTPMethod%22%3A%22GET%22%7D'

# support-x25519mlkem768: mihomo strips the X25519MLKEM768 key share unless a
# link asks for it, and Xray's REALITY refuses a client without it. Other
# clients look up the parameters they know and pass over this one.
# XHTTP first, then REALITY: an app tends to try the first link it holds, and
# REALITY with Vision over raw TCP is the transport blocked most often. REALITY
# stays, for networks where XHTTP is the one that fails.
links() { # <id> <label> <server>: each named "<label> [<transport>]"
  cat <<EOF
XHTTP over TLS via $3 (for a CDN in front: replace the address with the CDN's name):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&security=tls&sni=$3&host=$3&alpn=h2&fp=chrome&type=xhttp&path=%2F${path}&mode=auto#$2%20%5Bxhttp%5D

EOF
  [ -z "$xr_port" ] || cat <<EOF
XHTTP with REALITY via $3, on port ${xr_port} (v2rayN, v2rayNG, mihomo):
vless://$1@$3:${xr_port}?encryption=${enc}&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&support-x25519mlkem768=true&type=xhttp&path=%2F${path}&mode=auto#$2%20%5Bxhttp%2Breality%5D

EOF
  cat <<EOF
REALITY via $3 (v2rayN, v2rayNG, Hiddify, Happ, Streisand, mihomo):
vless://$1@$3:${HTTPS_PORT}?encryption=${enc}&flow=xtls-rprx-vision&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&support-x25519mlkem768=true&type=tcp#$2%20%5Breality%5D

EOF
  if [ -n "$kcp_port" ] && [ "$kcp_open" = quic ]; then cat <<EOF
mKCP via $3, on UDP port ${kcp_port}, QUIC-shaped opening (v2rayN, v2rayNG):
vless://$1@$3:${kcp_port}?encryption=${enc}&type=kcp&fm=$(fm_enc "$kcp_seed" "$kcp_header" quic)#$2%20%5Bkcp%5D

EOF
  elif [ -n "$kcp_port" ]; then cat <<EOF
mKCP via $3, on UDP port ${kcp_port} (v2rayN, v2rayNG):
vless://$1@$3:${kcp_port}?encryption=${enc}&type=kcp&headerType=${kcp_header}&seed=${kcp_seed}#$2%20%5Bkcp%5D

EOF
  fi
}

# A relay takes REALITY on 443 under its neighbour site's name, with keys of its
# own, and carries the device on to this server as its own client.
relay_links() { # <id> <label>: one per relay, named "<label> [relay <host>]", "[relay <host> xhttp]" and "[relay <host> cdn <cdn>]" before it through an own-site one, "[relay <host> kcp]" after it with mKCP
  printf '%s\n' "$relays" | while read -r h s k i e _ p c d; do
    [ -n "$h" ] || continue
    [ "$p" = - ] || cat <<EOF
XHTTP over TLS through the relay $h, behind its own site (v2rayN, v2rayNG, Happ):
vless://$1@$h:443?encryption=$e&security=tls&sni=$s&host=$s&alpn=h2&fp=chrome&type=xhttp&path=%2F$p&mode=auto#$2%20%5Brelay%20$h%20xhttp%5D

EOF
    [ "$d" = - ] || for x in $(printf '%s' "$d" | tr ',' ' '); do cat <<EOF
XHTTP through the CDN $x, in front of the relay $h (v2rayN, v2rayNG, Happ):
vless://$1@$x:443?encryption=$e&security=tls&sni=$x&host=$x&alpn=h2&fp=chrome&type=xhttp&path=%2F$p&mode=packet-up&extra=${cdn_extra}#$2%20%5Brelay%20$h%20cdn%20$x%5D

EOF
    done
    cat <<EOF
REALITY through the relay $h (v2rayN, v2rayNG, Hiddify, Happ, Streisand, mihomo):
vless://$1@$h:443?encryption=$e&flow=xtls-rprx-vision&security=reality&sni=$s&fp=chrome&pbk=$k&sid=$i&support-x25519mlkem768=true&type=tcp#$2%20%5Brelay%20$h%5D

EOF
    [ "$c" != - ] || continue
    kport=${c%%,*}; r=${c#*,}; kheader=${r%%,*}; r2=${r#*,}; kseed=${r2%%,*}
    kopen=none; case $r2 in *,*) kopen=${r2#*,} ;; esac
    if [ "$kopen" = quic ]; then cat <<EOF
mKCP through the relay $h, on UDP port ${kport}, QUIC-shaped opening (v2rayN, v2rayNG):
vless://$1@$h:${kport}?encryption=$e&type=kcp&fm=$(fm_enc "$kseed" "$kheader" quic)#$2%20%5Brelay%20$h%20kcp%5D

EOF
    else cat <<EOF
mKCP through the relay $h, on UDP port ${kport} (v2rayN, v2rayNG):
vless://$1@$h:${kport}?encryption=$e&type=kcp&headerType=${kheader}&seed=${kseed}#$2%20%5Brelay%20$h%20kcp%5D

EOF
    fi
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

cdn_outbound() { # <tag> <id> <cdn> <encryption> <path>: XHTTP through a CDN, uploading by GET with the data in headers
  cat <<EOF
    {"tag": "$1", "protocol": "vless",
     "settings": {"address": "$3", "port": 443, "id": "$2", "encryption": "$4"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$3", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/$5", "host": "$3", "mode": "packet-up",
         "uplinkHTTPMethod": "GET", "uplinkDataPlacement": "header", "uplinkChunkSize": 16384,
         "scMaxEachPostBytes": 32768, "scMinPostsIntervalMs": 10}}},
EOF
}

cdn_outbounds() { # <id>
  n=0
  for h in $cdns; do
    n=$((n + 1))
    cdn_outbound "dotdash-cdn-$n" "$1" "$h" "${enc}" "${path}"
  done
}

relay_outbounds() { # <id>
  n=0
  printf '%s\n' "$relays" | while read -r h s k i e _ p c d; do
    [ -n "$h" ] || continue
    n=$((n + 1))
    cat <<EOF
    {"tag": "dotdash-relay-$n", "protocol": "vless",
     "settings": {"address": "$h", "port": 443, "id": "$1", "encryption": "$e", "flow": "xtls-rprx-vision"},
     "streamSettings": {"network": "raw", "security": "reality",
       "realitySettings": {"serverName": "$s", "fingerprint": "chrome", "password": "$k", "shortId": "$i"}}},
EOF
    [ "$p" = - ] || cat <<EOF
    {"tag": "dotdash-relay-$n-xhttp", "protocol": "vless",
     "settings": {"address": "$h", "port": 443, "id": "$1", "encryption": "$e"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$s", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/$p", "host": "$s", "mode": "auto"}}},
EOF
    m=0
    [ "$d" = - ] || for x in $(printf '%s' "$d" | tr ',' ' '); do
      m=$((m + 1))
      cdn_outbound "dotdash-relay-$n-cdn-$m" "$1" "$x" "$e" "$p"
    done
    [ "$c" != - ] || continue
    kport=${c%%,*}; r=${c#*,}; kheader=${r%%,*}; r2=${r#*,}; kseed=${r2%%,*}
    kopen=none; case $r2 in *,*) kopen=${r2#*,} ;; esac
    cat <<EOF
    {"tag": "dotdash-relay-$n-kcp", "protocol": "vless",
     "settings": {"address": "$h", "port": ${kport}, "id": "$1", "encryption": "$e"},
     "streamSettings": {"network": "kcp", "finalmask": {"udp": [$(kcp_masks "$kseed" "$kheader" "$kopen")]}}},
EOF
  done
}

outbounds() { # <id>: a REALITY and an XHTTP outbound per server, the third, mKCP, the relays, the CDNs
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
    [ -z "$kcp_port" ] || cat <<EOF
    {"tag": "dotdash-$n-kcp", "protocol": "vless",
     "settings": {"address": "$s", "port": ${kcp_port}, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "kcp", "finalmask": {"udp": [$(kcp_masks "$kcp_seed" "$kcp_header" "$kcp_open")]}}},
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

sub_through() { # <token>: the same subscription through each own-site relay
  for r in $sub_relays; do
    printf 'through the relay %s: https://%s/%s\n' "$r" "$r" "$1"
  done
}

client() { # <id> <label>
  echo "== $2 =="
  if [ "${SUBSCRIPTION:-false}" = true ]; then
    # As subscription.sh names the device's file.
    token=$(printf '%s:%s' "$(cat /run/secrets/subscription_key)" "$1" | sha256sum | cut -c1-32)
    if [ "${HTTPS_PORT}" = 443 ]; then at=; else at=":${HTTPS_PORT}"; fi
    if ! $full; then
      printf 'https://%s%s/%s\n' "${DOMAIN}" "$at" "$token"
      sub_through "$token"
      echo
      return 0
    fi
    cat <<EOF
Subscription, for the app to fetch these links from and refresh them after a
revocation or a key rotation (as secret as the links):
https://${DOMAIN}${at}/${token}
EOF
    sub_through "$token"
    [ -z "$sub_relays" ] || echo "An app takes one: a device inside the restricted network gets one through a relay."
    echo
  fi
  for s in $servers; do
    if [ "$count" -gt 1 ]; then label="$2-$s"; else label=$2; fi
    links "$1" "$label" "$s"
  done
  relay_links "$1" "$2"
  cdn_links "$1" "$2"
  if [ "$count" -gt 1 ]; then where=" on any of the servers"; else where=; fi
  if [ -n "$xr_port" ]; then which="REALITY, XHTTP and XHTTP with REALITY"; else which="REALITY and XHTTP"; fi
  [ -z "$kcp_port" ] || which="${which}, or mKCP,"
  [ -z "$relays" ] || which="${which}, or a relay,"
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
  pick "${name:-}"
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
