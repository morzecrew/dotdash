#!/usr/bin/env bash
# The metrics profile, beside CI's xdns: exporters in Xray's and the gate's
# network namespaces write each one's traffic per inbound and outbound, and
# the gate's verdicts on its upstreams, into the textfile directory every
# minute, as 65532 and with nothing published, so the policy hook (run after
# the apply) still holds; back on xdns, they're gone. The directory is the
# rig's own, owned by 65532 here as an operator's ACL would make it writable.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'metrics: [compose/metrics.yaml]' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

dir=/rig/textfile
sudo install -d -o 65532 -g 65532 -m 0755 "${dir}"
set_config "metrics_textfile=${dir}"
set_config installation.profile=xdns,metrics

for _ in $(seq 40); do
  sudo grep -qF 'dotdash_xray_up{product="dotdash",role="xray"} 1' "${dir}/dotdash-dotdash-xray.prom" 2>/dev/null &&
    sudo grep -qF 'dotdash_xray_up{product="dotdash",role="gate"} 1' "${dir}/dotdash-dotdash-gate.prom" 2>/dev/null && break
  sleep 5
done
xray=$(sudo cat "${dir}/dotdash-dotdash-xray.prom" 2>/dev/null || true)
gate=$(sudo cat "${dir}/dotdash-dotdash-gate.prom" 2>/dev/null || true)
grep -qF 'dotdash_xray_up{product="dotdash",role="xray"} 1' <<<"${xray}" || die "no answer from Xray's metrics: ${xray:-no file}"
grep -qF 'dotdash_xray_up{product="dotdash",role="gate"} 1' <<<"${gate}" || die "no answer from the gate's metrics: ${gate:-no file}"
grep -qE '^dotdash_inbound_bytes_total\{product="dotdash",role="xray",inbound="reality",direction="downlink"\} [0-9]+$' <<<"${xray}" ||
  die "Xray's file has no REALITY inbound counter: ${xray}"
grep -qE '^dotdash_observatory_alive\{product="dotdash",role="gate",outbound="upstream-[^"]*"\} [01]$' <<<"${gate}" ||
  die "the gate's file has no verdict on an upstream: ${gate}"
! grep -q 'user' <<<"${xray}${gate}" || die "a metrics file names a user"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under the metrics profile: ${out}"
echo "56-metrics.sh: under metrics, Xray's and the gate's traffic and verdicts reach the textfile directory, policy holding"

set_config installation.profile=xdns
[ -z "$(sudo docker ps -q --filter label=com.docker.compose.service=metrics-xray)" ] || die "back on xdns, an exporter still runs"
sudo morzer config unset metrics_textfile >/dev/null || die "could not unset metrics_textfile"
sudo rm -rf "${dir}"
echo "56-metrics.sh: back on xdns, the exporters are gone"
