#!/bin/sh
# This server's facts, as JSON, for an authority managing several machines:
# morzer publishes them to it after every change when sync.recipient is set
# (manifest `published`). Public halves and addresses only: the REALITY public
# key and the VLESS encryption string are what every device's link carries.
# The shared keys themselves come from the authority, which made them.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
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
printf '}\n'
