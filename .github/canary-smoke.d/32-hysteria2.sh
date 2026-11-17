#!/usr/bin/env bash
# The hysteria2 profile: the canary checks Hysteria2 beside REALITY, against
# the stand-in server's 443/udp (pre-apply/10-server.sh), logging in as
# dotdash_id. No public CA signed the stand-in's certificate, so getting
# through means the canary pinned it (dotdash_hysteria2_pin). CI installs
# no profile, and a published release that declares none of this, so this
# switches to it at runtime and back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'hysteria2: [compose/hysteria2.yaml]' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

transports() { # <count>: the measure task's transports, each with how many got through
  local out
  out=$(sudo morzer task run measure --output -- "$1" 2>&1) || die "measure failed: ${out}"
  sed -n '/^{/,/^}/p' <<<"${out}" | jq -c '.transports | map_values(.ok)'
}

sudo morzer config set "dotdash_hysteria2_pin=$(cat /rig/hy2-pin)" >/dev/null || die "could not set the pin"
sudo morzer config set installation.profile=hysteria2 >/dev/null || die "could not switch to the hysteria2 profile"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under hysteria2: ${out}"
got=$(transports 3)
jq -e 'keys == ["hysteria2", "reality"] and .hysteria2 >= 1' <<<"${got}" >/dev/null || die "measure under hysteria2: ${got}"
out=$(sudo morzer task run facts --output 2>&1) || die "facts failed: ${out}"
grep -m1 '^{' <<<"${out}" | jq -e '.paths.hysteria2 == true and (.latency_ms.hysteria2 | type) == "number"' >/dev/null \
  || die "facts under hysteria2: ${out}"
echo "32-hysteria2.sh: under hysteria2 the canary gets through Hysteria2 too: ${got}"

sudo morzer config unset installation.profile dotdash_hysteria2_pin >/dev/null || die "could not go back to no profile"
got=$(transports 1)
jq -e 'keys == ["reality"]' <<<"${got}" >/dev/null || die "measure after going back: ${got}"
echo "32-hysteria2.sh: back to no profile, the canary checks REALITY alone"
