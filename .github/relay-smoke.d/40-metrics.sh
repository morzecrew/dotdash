#!/usr/bin/env bash
# The metrics profile: an exporter on a network of its own writes the relay's
# traffic per inbound and outbound, and its verdicts on the servers, into the
# textfile directory every minute. It follows Xray through a recreate (morzer
# restart xray), after which a secret's restart of Xray still succeeds, which
# an exporter in its namespace broke; dropping the profile takes it away. The
# directory is the rig's own, owned by 65532 here as an operator's ACL would
# make it writable.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'metrics: [compose/metrics.yaml]' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

dir=/rig/textfile
sudo install -d -o 65532 -g 65532 -m 0755 "${dir}"
sudo morzer config set "metrics_textfile=${dir}" >/dev/null || die "could not set metrics_textfile"
sudo morzer config set installation.profile=metrics >/dev/null || die "could not switch to the metrics profile"
file="${dir}/dotdash-dotdash-relay-xray.prom"
up() { # <tries>: whether the file says up within that many 5 s waits
  for _ in $(seq "$1"); do
    sudo grep -qF 'dotdash_xray_up{product="dotdash-relay",role="xray"} 1' "${file}" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}
up 40 || true
out=$(sudo cat "${file}" 2>/dev/null || true)
grep -qF 'dotdash_xray_up{product="dotdash-relay",role="xray"} 1' <<<"${out}" || die "no answer from the relay's metrics: ${out:-no file}"
grep -qE '^dotdash_inbound_bytes_total\{product="dotdash-relay",role="xray",inbound="devices",direction="downlink"\} [0-9]+$' <<<"${out}" ||
  die "the relay's file has no devices inbound counter: ${out}"
grep -qE '^dotdash_outbound_bytes_total\{product="dotdash-relay",role="xray",outbound="dotdash-0",' <<<"${out}" ||
  die "the relay's file has no counter for its link to the server: ${out}"
echo "40-metrics.sh: under metrics, the relay's traffic reaches the textfile directory"

sudo morzer restart xray >/dev/null || die "morzer restart xray failed under metrics"
device=$(cat /rig/relay/device)
printf '%s phone\n%s spare\n' "${device}" "$(cat /proc/sys/kernel/random/uuid)" | sudo morzer secret set vless_clients >/dev/null ||
  die "after Xray was recreated, a change of vless_clients failed to restart it under metrics"
printf '%s phone\n' "${device}" | sudo morzer secret set vless_clients >/dev/null || die "could not restore vless_clients"
sudo rm -f "${file}"
up 30 || die "after Xray was recreated, the exporter no longer reaches it"
echo "40-metrics.sh: the exporter follows a recreated Xray, and a secret's restart of it still succeeds"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the metrics profile"
[ -z "$(sudo docker ps -q --filter label=com.docker.compose.service=metrics-xray)" ] || die "without the profile, the exporter still runs"
sudo morzer config unset metrics_textfile >/dev/null || die "could not unset metrics_textfile"
sudo rm -rf "${dir}"
echo "40-metrics.sh: without the profile, the exporter is gone"
