#!/usr/bin/env bash
# The metrics profile: an exporter on a network of its own writes the relay's
# traffic per inbound and outbound, its verdicts on the servers, and each
# server group's state from the gateway's status (dotdash_group_*), into the
# textfile directory every minute. It follows Xray through a recreate (morzer
# restart xray), after which a secret's restart of Xray still succeeds, which
# an exporter in its namespace broke; dropping the profile takes it away. The
# directory is the rig's own, owned by 65532 here as an operator's ACL would
# make it writable.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

dir=/rig/textfile
sudo install -d -o 65532 -g 65532 -m 0755 "${dir}"
sudo morzer config set "metrics_textfile=${dir}" >/dev/null || die "could not set metrics_textfile"
sudo morzer config set installation.profile=metrics >/dev/null || die "could not switch to the metrics profile"
file="${dir}/dotdash-dotdash-relay-xray.prom"
has() { # <line> <tries>: whether the file holds that line within that many 5 s waits
  for _ in $(seq "$2"); do
    sudo grep -qxF "$1" "${file}" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}
up() { has 'dotdash_xray_up{product="dotdash-relay",role="xray"} 1' "$1"; }
# The exporter writes every minute, and the gateway's first round after
# Xray was re-created for the profile may come after its first write.
up 40 || true
has 'dotdash_group_live{product="dotdash-relay",role="xray",group="s1"} 1' 30 || true
out=$(sudo cat "${file}" 2>/dev/null || true)
grep -qF 'dotdash_xray_up{product="dotdash-relay",role="xray"} 1' <<<"${out}" || die "no answer from the relay's metrics: ${out:-no file}"
grep -qE '^dotdash_inbound_bytes_total\{product="dotdash-relay",role="xray",inbound="devices",direction="downlink"\} [0-9]+$' <<<"${out}" ||
  die "the relay's file has no devices inbound counter: ${out}"
grep -qE '^dotdash_outbound_bytes_total\{product="dotdash-relay",role="xray",outbound="s1-0",' <<<"${out}" ||
  die "the relay's file has no counter for its link to s1's server: ${out}"
grep -qF 'dotdash_group_live{product="dotdash-relay",role="xray",group="s1"} 1' <<<"${out}" ||
  die "the relay's file does not say s1 is live: ${out}"
grep -qF 'dotdash_group_devices{product="dotdash-relay",role="xray",group="s1"} 1' <<<"${out}" ||
  die "the relay's file does not count s1's one device: ${out}"
grep -qE '^dotdash_group_list_age_seconds\{product="dotdash-relay",role="xray",group="s1"\} [0-9]+$' <<<"${out}" ||
  die "the relay's file has no age of s1's list: ${out}"
echo "40-metrics.sh: under metrics, the relay's traffic and each group's state reach the textfile directory"

sudo morzer restart xray >/dev/null || die "morzer restart xray failed under metrics"
line=$(cat /rig/relay/server-line)
printf '# s1\n%s\n' "${line}" | sudo morzer secret set servers >/dev/null ||
  die "after Xray was recreated, a change of servers failed to restart it under metrics"
printf '%s\n' "${line}" | sudo morzer secret set servers >/dev/null || die "could not restore servers"
sudo rm -f "${file}"
up 30 || die "after Xray was recreated, the exporter no longer reaches it"
echo "40-metrics.sh: the exporter follows a recreated Xray, and a secret's restart of it still succeeds"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the metrics profile"
[ -z "$(sudo docker ps -q --filter label=com.docker.compose.service=metrics-xray)" ] || die "without the profile, the exporter still runs"
sudo morzer config unset metrics_textfile >/dev/null || die "could not unset metrics_textfile"
sudo rm -rf "${dir}"
echo "40-metrics.sh: without the profile, the exporter is gone"
