#!/bin/sh
# Checks each of this relay's entries as a device reaches it, end to end, and
# prints a line per entry: ok, or FAIL and why. An Xray client in Xray's own
# namespace dials each inbound on loopback, with the relay's own keys and the
# first device's id in vless_clients, and fetches probe_url through it, on to
# the servers: REALITY; under own-site, XHTTP through the site, its TLS
# pinned to the site's certificate; under mkcp, mKCP; under hysteria2,
# Hysteria2. First, the way on to the servers alone, through Xray's probe
# inbound, which every entry needs. Under http-origin, the door's own log
# (caddy/Caddyfile) says what reached it in the last hour: nothing (a
# firewall), all refused from Docker's own address (docker-proxy hides the
# CDN's), all refused from others (http_origin_from), or some passed.
#
# What it can't see is the way from devices' networks to this machine: its
# address, ports and firewall. Only a canary on such a network sees that.
set -eu
# Any address: entry.sh needs one, and nothing here dials it.
set -- 127.0.0.1
# shellcheck source=entry.sh
. /task/entry.sh

id=$(awk '$1 !~ /^#/ && NF { print $1; exit }' /run/secrets/vless_clients)
[ -n "$id" ] || { echo "entry-check: vless_clients lets no device in, so there is none to check as" >&2; exit 1; }
failed=0
say() { printf '%-8s %s\n' "$1" "$2"; case $2 in FAIL*) failed=1 ;; esac; }

# The site's certificate as Xray pins it, the leaf's SHA-256 as openssl
# prints it, so a check through the site needs no CA, Caddy's own included.
pin=
if [ -n "$cert_file" ] && [ -s "$cert_file" ]; then
  pin=$(awk '/-----END/ { exit } f; /-----BEGIN/ { f = 1 }' "$cert_file" | base64 -d | sha256sum | cut -c1-64 |
    tr a-f A-F | sed 's/../&:/g; s/:$//')
fi

fetch() { # <proxy port>: nothing when probe_url came back through it, in two tries; else why not
  for try in 1 2; do
    if out=$(XRAY_HEALTHCHECK_PROXY="http://127.0.0.1:$1" XRAY_HEALTHCHECK_URL="$PROBE_URL" XRAY_HEALTHCHECK_TIMEOUT=10s \
      /opt/xray/xray-entrypoint healthcheck 2>&1); then
      return 0
    fi
    [ "$try" = 2 ] || sleep 1
  done
  why=$(printf '%s\n' "$out" | sed -n 's/^healthcheck: GET .* through [^ ]*: //p' | tail -n1)
  printf '%s' "${why:-no answer}"
}
# check <outbound>: fetch through an Xray client of one entry, a device's,
# on 127.0.0.1:20801; when that fails, Xray's own last word on why.
check() {
  printf '{"log": {"loglevel": "warning", "access": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": 20801, "protocol": "http"}], "outbounds": [{%s}]}\n' \
    "$1" >/tmp/check.json
  /opt/xray/xray run -c /tmp/check.json >/tmp/xray.log 2>&1 &
  client=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    ! nc -z 127.0.0.1 20801 2>/dev/null || break
    sleep 1
  done
  why=$(fetch 20801)
  kill "$client" 2>/dev/null || true
  wait "$client" 2>/dev/null || true
  [ -n "$why" ] || return 0
  xray=$(grep -E '\[(Warning|Error)\]' /tmp/xray.log | tail -n1 | sed 's/^[^]]*\] \(\[[0-9]*\] \)\{0,1\}//' | cut -c1-300)
  printf '%s' "${xray:-$why}"
}
trap 'kill "${client:-}" 2>/dev/null || true' EXIT
vless() { # <port> <stream settings> [flow]: a VLESS outbound as a device's link has it
  printf '"protocol": "vless", "settings": {"address": "127.0.0.1", "port": %s, "id": "%s", "encryption": "%s"%s}, "streamSettings": {%s}' \
    "$1" "$id" "$enc" "${3:+, \"flow\": \"$3\"}" "$2"
}
tls() { # <alpn>: the site's TLS, pinned to its certificate
  printf '"security": "tls", "tlsSettings": {"serverName": "%s", "alpn": ["%s"], "fingerprint": "chrome", "pinnedPeerCertSha256": "%s"}' \
    "$SITE" "$1" "$pin"
}
entry() { # <entry> <what works when it does> <outbound>
  why=$(check "$3")
  if [ -z "$why" ]; then say "$1" "ok: $2"; else say "$1" "FAIL: $why"; fi
}

why=$(fetch 10809)
if [ -z "$why" ]; then
  say servers "ok: the relay reaches the servers, or the relays in via"
else
  say servers "FAIL: the relay reaches no server ($why): every entry below fails with it; see doctor"
fi
entry reality "a device's REALITY link under ${SITE} gets through" \
  "$(vless 443 "\"network\": \"raw\", \"security\": \"reality\", \"realitySettings\": {\"serverName\": \"${SITE}\", \"fingerprint\": \"chrome\", \"password\": \"${pbk}\", \"shortId\": \"${sid}\"}" xtls-rprx-vision)"
if [ -n "$path$hy2_port" ] && [ -z "$pin" ]; then
  say site "FAIL: Caddy has no certificate for ${SITE} yet, so neither XHTTP nor Hysteria2 through the site works: check its ACME"
elif [ -n "$path" ]; then
  entry xhttp "the site passes the XHTTP path on to Xray, under its own certificate" \
    "$(vless 443 "\"network\": \"xhttp\", $(tls h2), \"xhttpSettings\": {\"path\": \"/${path}\", \"host\": \"${SITE}\", \"mode\": \"auto\"}")"
fi
if [ -n "$kcp_seed" ]; then
  mask="{\"type\": \"mkcp-legacy\", \"settings\": {\"value\": \"${kcp_seed}\"}}"
  [ "${KCP_HEADER:-dtls}" = none ] || mask="$mask, {\"type\": \"mkcp-legacy\", \"settings\": {\"header\": \"${KCP_HEADER:-dtls}\"}}"
  [ "${KCP_OPEN:-none}" != quic ] ||
    mask="$mask, {\"type\": \"noise\", \"settings\": {\"noise\": [{\"type\": \"hex\", \"packet\": \"c300000001088394c8f03e5157080000449e00000002\", \"delay\": \"0-0\"}]}}"
  entry mkcp "mKCP answers on UDP ${KCP_PORT}" "$(vless 8447 "\"network\": \"kcp\", \"finalmask\": {\"udp\": [${mask}]}")"
fi
[ -z "$hy2_port" ] || [ -z "$pin" ] ||
  entry hy2 "Hysteria2 answers on UDP ${hy2_port}, under the site's certificate" \
    "\"protocol\": \"hysteria\", \"settings\": {\"version\": 2, \"address\": \"127.0.0.1\", \"port\": 8448}, \"streamSettings\": {\"network\": \"hysteria\", $(tls h3), \"hysteriaSettings\": {\"version\": 2, \"auth\": \"${id}\"}}"
[ -z "$cdn" ] || say cdn "not checked here: a CDN's half takes a fetch through it, which cdn-check on a server makes"


# The door's log, the last hour of it: how many requests, how many passed
# (Xray's answer, not the door's 404), and from how many addresses it
# refused them, the first three named.
if [ -n "${HTTP_ORIGIN_PORT:-}" ]; then
  if [ "${HTTP_ORIGIN_FROM:-none}" = none ]; then
    say door "FAIL: http_origin_from is none, so the door answers no one: set the CDN's gateways, or any"
  elif [ ! -f /door-log/door.log ]; then
    say door "FAIL: no door log: is Caddy running? (doctor)"
  else
    # shellcheck disable=SC2046 # four words
    set -- $(awk -v since=$(($(date +%s) - 3600)) '
      match($0, /"ts":[0-9.]+/) { ts = substr($0, RSTART + 5, RLENGTH - 5) + 0 }
      ts < since { next }
      match($0, /"remote_ip":"[^"]*"/) { ip = substr($0, RSTART + 13, RLENGTH - 14) }
      match($0, /"status":[0-9]+/) { st = substr($0, RSTART + 9, RLENGTH - 9) + 0 }
      { n++ }
      st != 404 { ok++; next }
      !(ip in seen) { seen[ip] = 1; k++; if (k <= 3) list = list (k > 1 ? "," : "") ip }
      END { print n + 0, ok + 0, k + 0, (list == "" ? "-" : list) }' /door-log/door.log)
    if [ "$1" = 0 ]; then
      say door "FAIL: no request reached the door in the last hour: the CDN doesn't reach port ${HTTP_ORIGIN_PORT} (a firewall, or another port given to the CDN)"
    elif [ "$2" != 0 ]; then
      say door "ok: $2 of $1 requests in the last hour went on to Xray"
    else
      case $3:$4 in
        1:10.* | 1:192.168.* | 1:172.1[6-9].* | 1:172.2[0-9].* | 1:172.3[01].*)
          say door "FAIL: all $1 requests in the last hour refused, all from $4, Docker's own address: docker-proxy hides the CDN's (over IPv6, or with its userland proxy). Set http_origin_from=any, or listen=0.0.0.0 to publish the door on IPv4 alone" ;;
        *)
          say door "FAIL: all $1 requests in the last hour refused, from $3 address(es) ($4): if they are the CDN's, add its ranges to http_origin_from; if they are in it, the CDN asks for a path other than the one relay-entry printed" ;;
      esac
    fi
  fi
  [ -n "$origin" ] || say door "(http_origin_host is none: devices get no link through the door yet)"
fi
echo "Checked inside the relay: whether devices' networks reach its address and ports, only a canary there sees."
exit "$failed"
