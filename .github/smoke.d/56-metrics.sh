#!/usr/bin/env bash
# The metrics profile, beside CI's xdns: exporters on a network of their own
# write Xray's and the gate's traffic per inbound and outbound, and the
# gate's verdicts on its upstreams, into the textfile directory every
# minute, as 65532 and with nothing published, so the policy hook (run after
# the apply) still holds. They follow Xray and the gate through a recreate
# (morzer restart), after which a secret's restart of Xray still succeeds,
# which an exporter in its namespace broke; back on xdns, they're gone. The directory is the
# rig's own, owned by 65532 here as an operator's ACL would make it writable.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

dir=/rig/textfile
sudo install -d -o 65532 -g 65532 -m 0755 "${dir}"
set_config "metrics_textfile=${dir}"
set_config installation.profile=xdns,metrics

both_up() { # [tries]: whether both files say up within that many 5 s waits
  for _ in $(seq "$1"); do
    sudo grep -qF 'dotdash_xray_up{product="dotdash",role="xray"} 1' "${dir}/dotdash-dotdash-xray.prom" 2>/dev/null &&
      sudo grep -qF 'dotdash_xray_up{product="dotdash",role="gate"} 1' "${dir}/dotdash-dotdash-gate.prom" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}
both_up 40 || true
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

sudo morzer restart xray >/dev/null || die "morzer restart xray failed under metrics"
sudo morzer restart gate >/dev/null || die "morzer restart gate failed under metrics"
secrets=/run/dotdash/secrets
before=$(sudo cat "${secrets}/vless_clients")
printf '%s\n%s spare\n' "${before}" "$(cat /proc/sys/kernel/random/uuid)" | sudo morzer secret set vless_clients >/dev/null ||
  die "after Xray was recreated, a change of vless_clients failed to restart it under metrics"
printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null || die "could not restore vless_clients"
sudo rm -f "${dir}"/dotdash-dotdash-*.prom
both_up 30 || die "after Xray and the gate were recreated, an exporter no longer reaches them"
echo "56-metrics.sh: the exporters follow a recreated Xray and gate, and a secret's restart of Xray still succeeds"

set_config installation.profile=xdns
[ -z "$(sudo docker ps -q --filter label=com.docker.compose.service=metrics-xray)" ] || die "back on xdns, an exporter still runs"
sudo morzer config unset metrics_textfile >/dev/null || die "could not unset metrics_textfile"
sudo rm -rf "${dir}"
echo "56-metrics.sh: back on xdns, the exporters are gone"
