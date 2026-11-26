#!/usr/bin/env bash
# The measure task reports each transport this canary runs as JSON: here only
# REALITY (CI installs no xhttp profile), through the rig's stand-in server
# (pre-apply/10-server.sh), with every fetch counted and latencies for the ones
# that succeeded, and three downloads of download_url with the median
# Mbit/s. download_url is a stand-in site only
# the stand-in server reaches (lib/sites.sh), so a download counted went
# through dotdash.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
# shellcheck source=lib/sites.sh
. "${0%/*}/lib/sites.sh"
set -euo pipefail

# A release from before the measure task has nothing to check.
if ! sudo grep -qF '  measure:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

start_sites
sudo morzer config set "download_url=${sites}/down" >/dev/null || die "could not set download_url"
out=$(sudo morzer task run measure --output -- 5 2>&1) || die "measure failed: ${out}"
sudo morzer config unset download_url >/dev/null || die "could not unset download_url"
json=$(sed -n '/^{/,/^}/p' <<<"${out}")
jq -e '
  (.transports | keys) == ["reality"]
  and (.transports.reality | .requests == 5 and .ok + .timeouts + .errors == 5 and .ok >= 1)
  and (.transports.reality.latency_ms | .p50 <= .p95 and .p95 <= .max)
  and (.transports.reality.download | .of == 3 and .ok >= 1 and .mbps_p50 > 0)
' <<<"${json}" >/dev/null || die "measure reported something else, or no downloads through REALITY: ${out}"
echo "20-measure.sh: $(jq -c '.transports.reality | {ok, success_rate, latency_ms, download}' <<<"${json}")"
