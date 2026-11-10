#!/usr/bin/env bash
# The measure task reports each transport this canary runs as JSON: here only
# REALITY (CI installs no xhttp profile), through the rig's stand-in server
# (pre-apply/10-server.sh), with every fetch counted and latencies for the ones
# that succeeded, and, from a release with them, three downloads of
# download_url with the median Mbit/s.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before the measure task has nothing to check.
if ! sudo grep -qF '  measure:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

out=$(sudo morzer task run measure --output -- 5 2>&1) || die "measure failed: ${out}"
json=$(sed -n '/^{/,/^}/p' <<<"${out}")
jq -e '
  (.transports | keys) == ["reality"]
  and (.transports.reality | .requests == 5 and .ok + .timeouts + .errors == 5 and .ok >= 1)
  and (.transports.reality.latency_ms | .p50 <= .p95 and .p95 <= .max)
' <<<"${json}" >/dev/null || die "measure reported something else: ${out}"
if sudo grep -qF 'download_url' /opt/dotdash-canary/current/tasks/measure.sh; then
  jq -e '.transports.reality.download | .of == 3 and .ok >= 1 and .mbps_p50 > 0' <<<"${json}" >/dev/null ||
    die "measure reported no downloads through REALITY: ${out}"
fi
echo "20-measure.sh: $(jq -c '.transports.reality | {ok, success_rate, latency_ms, download}' <<<"${json}")"
