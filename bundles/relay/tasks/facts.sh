#!/bin/sh
# This relay's facts, as JSON: relay-entry's line, for an authority managing
# several machines. morzer publishes them to it after every change when
# sync.recipient is set (manifest `published`). Besides public halves they
# carry the short id, and under own-site the XHTTP path (and the CDNs' with
# cdn_hosts) and under mkcp the
# seed (and under hysteria2 its port, and its name when set): credentials, but the ones every device's link through this relay
# carries, so the authority hands them on to devices.
set -eu
# shellcheck source=entry.sh
. /task/entry.sh

# A JSON string: backslashes and quotes escaped. Every value here is a name, a
# number or base64, so a control character means something is wrong.
str() {
  case $1 in *[[:cntrl:]]*) echo "facts: a value holds a control character" >&2; exit 1 ;; esac
  printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}

printf '{"entry_host": %s, "site": %s, "public_key": %s, "short_id": %s, "encryption": %s' \
  "$(str "$host")" "$(str "$SITE")" "$(str "$pbk")" "$(str "$sid")" "$(str "$enc")"
[ -z "$path" ] || printf ', "own_site": {"xhttp_path": %s}' "$(str "$path")"
[ -z "$kcp_seed" ] ||
  printf ', "kcp": {"port": %s, "header": %s, "open": %s, "seed": %s}' \
    "$KCP_PORT" "$(str "${KCP_HEADER:-dtls}")" "$(str "${KCP_OPEN:-none}")" "$(str "$kcp_seed")"
[ -z "$hy2_port" ] || printf ', "hysteria2": {"port": %s}' "$hy2_port"
[ -z "$cdn" ] || printf ', "cdn_hosts": [%s]' "$(printf '%s' "$cdn" | sed 's/[^,]*/"&"/g; s/,/, /g')"
[ -z "$cdn_path" ] || printf ', "cdn_path": %s' "$(str "$cdn_path")"
[ -z "$origin" ] || printf ', "origin_host": %s' "$(str "$origin")"
[ -z "$only" ] || printf ', "cdn_only": true'
[ -z "$name" ] || printf ', "name": %s' "$(str "$name")"
# With the device-traffic profile, in Xray's namespace: the bytes each device
# has moved through Xray, both ways, since it started, by name, and when that
# was, from its StatsService on loopback. Left out, with a word on stderr, when
# Xray does not answer within 5 s, so the rest still goes out. A name that
# would need escaping in JSON is left out too.
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
# This release takes via: an authority sets or unsets it only on one that does.
printf ', "via": true}\n'
