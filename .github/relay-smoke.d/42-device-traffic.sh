#!/usr/bin/env bash
# The device-traffic profile: the relay's Xray counts each device's bytes, as
# the server counts the relay alone, and the facts task, run in Xray's
# namespace, carries them by device name. 10-through.sh's phone, started
# again from its config, raises the counts. Without the profile, the facts
# carry none. The rig's relay has no entry_host, which facts needs
# (12-facts.sh): set here, and unset after.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'device-traffic: [compose/device-traffic.yaml]' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
restore() {
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo morzer config unset entry_host >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-counted >/dev/null 2>&1 || true
}
trap restore EXIT
fetch() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --proxy http://127.0.0.1:18081 https://www.gstatic.com/generate_204 || true
}
counted() { # the phone's bytes in the facts' counts
  local facts
  facts=$(sudo morzer task run facts --output) || die "the facts task failed under device-traffic"
  jq -e '.entry_host and (.traffic.started | type == "number")' >/dev/null <<<"${facts}" ||
    die "the facts carry no counts under device-traffic: ${facts}"
  jq '.traffic.devices.phone // 0' <<<"${facts}"
}

sudo morzer config set entry_host=127.0.0.1 >/dev/null || die "could not set entry_host"
sudo morzer config set installation.profile=device-traffic >/dev/null || die "could not switch to the device-traffic profile"
sudo docker run -d --name relay-rig-counted --network host -v /rig/relay/phone:/etc/xray:ro "${xray}" >/dev/null
[ "$(fetch)" = 204 ] || die "the phone got nowhere through the relay under device-traffic"
first=$(counted)
[ "${first}" -gt 0 ] || die "a fetch through the phone left no count"
fetch >/dev/null
second=$(counted)
[ "${second}" -gt "${first}" ] || die "a second fetch did not raise the phone's count (${first}, then ${second})"
echo "${0##*/}: under device-traffic, the facts count the phone's bytes through the relay"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the device-traffic profile"
facts=$(sudo morzer task run facts --output) || die "the facts task failed without the profile"
jq -e 'has("traffic") | not' >/dev/null <<<"${facts}" || die "without the profile, the facts still carry counts"
echo "${0##*/}: without the profile, the facts carry no counts"
