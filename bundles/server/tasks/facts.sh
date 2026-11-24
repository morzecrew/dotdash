#!/bin/sh
# This server's facts, as JSON, for an authority managing several machines:
# morzer publishes them to it after every change when sync.recipient is set
# (manifest `published`). Public halves and addresses only: the REALITY public
# key and the VLESS encryption string are what every device's link carries.
# The shared keys themselves come from the authority, which made them.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
# The port others dial: entry_port, when a proxy on this machine passes the
# domain through to https_port.
case ${ENTRY_PORT:-none} in none) ;; '' | *[!0-9]*) echo "entry_port is not a port: ${ENTRY_PORT}" >&2; exit 1 ;; *) HTTPS_PORT=$ENTRY_PORT ;; esac
# A JSON string: backslashes and quotes escaped. Every value here is a name, a
# number or base64, so a control character means something is wrong.
str() {
  case $1 in *[[:cntrl:]]*) echo "facts: a value holds a control character" >&2; exit 1 ;; esac
  printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}

printf '{"domain": %s, "https_port": %s' "$(str "$DOMAIN")" "$HTTPS_PORT"
printf ', "public_key": %s' "$(str "$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)")"
printf ', "encryption": %s' "$(str "$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)")"
printf ', "subscription": %s' "$([ "${SUBSCRIPTION:-false}" = true ] && echo true || echo false)"
# Set under their profiles only, as for client-config.
[ -z "${XHTTP_REALITY_PORT:-}" ] || printf ', "xhttp_reality_port": %s' "$XHTTP_REALITY_PORT"
[ -z "${KCP_PORT:-}" ] ||
  printf ', "kcp": {"port": %s, "header": %s, "open": %s}' "$KCP_PORT" "$(str "${KCP_HEADER:-dtls}")" "$(str "${KCP_OPEN:-none}")"
[ -z "${HYSTERIA2_PORT:-}" ] || printf ', "hysteria2_port": %s' "$HYSTERIA2_PORT"
# With the device-traffic profile, in Xray's namespace: the bytes each device
# has moved through Xray, both ways, since it started, by name, and when that
# was, from its StatsService on loopback. Left out, with a word on stderr, when
# Xray does not answer within 5 s, so the rest still goes out. A device with
# no name in vless_clients is not counted (Xray counts by name), and a name
# that would need escaping in JSON is left out.
if [ "${DEVICE_TRAFFIC:-false}" = true ]; then
  up=
  for _ in 1 2 3 4 5; do
    up=$(/opt/xray/xray api statssys --server=127.0.0.1:10085 2>/dev/null | sed -n 's/^ *"Uptime": *\([0-9]*\).*/\1/p')
    [ -z "$up" ] || break
    sleep 1
  done
  if [ -n "$up" ]; then
    /opt/xray/xray api statsquery --server=127.0.0.1:10085 -pattern 'user>>>' 2>/dev/null |
      awk -F'"' -v "started=$(($(date +%s) - up))" '
        $2 == "name" { split($4, p, ">>>"); n = p[2] }
        $2 == "value" && n ~ /^[A-Za-z0-9._@+-]+$/ { v = $3; gsub(/[^0-9]/, "", v); t[n] += v }
        END {
          printf ", \"traffic\": {\"started\": %.0f, \"devices\": {", started
          s = ""; for (n in t) { printf "%s\"%s\": %.0f", s, n, t[n]; s = ", " }
          printf "}}"
        }'
  else
    echo "facts: Xray's stats did not answer: no traffic this time" >&2
  fi
fi
printf '}\n'
