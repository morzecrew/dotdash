#!/bin/sh
# This relay's facts, as JSON: relay-entry's line, for an authority managing
# several machines. morzer publishes them to it after every change when
# sync.recipient is set (manifest `published`). Besides public halves they
# carry the short id, and under own-site the XHTTP path and under mkcp the
# seed: credentials, but the ones every device's link through this relay
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
[ -z "$cdn" ] || printf ', "cdn_hosts": [%s]' "$(printf '%s' "$cdn" | sed 's/[^,]*/"&"/g; s/,/, /g')"
printf '}\n'
