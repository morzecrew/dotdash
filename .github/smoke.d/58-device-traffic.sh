#!/usr/bin/env bash
# The device-traffic profile, beside CI's xdns: Xray counts each device's
# bytes, and the facts task, run in Xray's namespace, carries them by device
# name with when Xray started. A fetch through 10-clients.sh's REALITY client
# raises the counts, and the policy hook still holds (doctor). Back on xdns,
# the facts carry no counts.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'device-traffic: [compose/device-traffic.yaml]' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi
restore() { sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true; }
trap restore EXIT
fetch() { # through 10-clients.sh's REALITY client
  curl -sS -o /dev/null --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors \
    -w '%{http_code}' --socks5-hostname 127.0.0.1:11080 http://11.99.0.10:8000/
}
counted() { # the bytes in the facts' counts, all devices together
  local facts
  facts=$(sudo morzer task run facts --output) || die "the facts task failed under device-traffic"
  jq -e '.domain and (.traffic.started | type == "number") and (.traffic.devices | type == "object")' \
    >/dev/null <<<"${facts}" || die "the facts carry no counts under device-traffic: ${facts}"
  jq '[.traffic.devices[]] | add // 0' <<<"${facts}"
}

sudo morzer config set installation.profile=xdns,device-traffic >/dev/null || die "could not switch to xdns,device-traffic"
[ "$(fetch)" = 200 ] || die "the REALITY client got nowhere under device-traffic"
first=$(counted)
[ "${first}" -gt 0 ] || die "a fetch through a device left no count"
fetch >/dev/null
second=$(counted)
[ "${second}" -gt "${first}" ] || die "a second fetch did not raise the counts (${first}, then ${second})"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under device-traffic: ${out}"
echo "${0##*/}: under device-traffic, the facts count each device's bytes, policy holding"

restore
facts=$(sudo morzer task run facts --output) || die "the facts task failed back on xdns"
jq -e 'has("traffic") | not' >/dev/null <<<"${facts}" || die "back on xdns, the facts still carry counts"
echo "${0##*/}: back on xdns, the facts carry no counts"
