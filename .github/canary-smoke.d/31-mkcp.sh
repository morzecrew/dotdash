#!/usr/bin/env bash
# The mkcp profile: the canary checks mKCP beside REALITY, against the
# stand-in server's 8447/udp (pre-apply/10-server.sh). CI installs no profile,
# and a published release that declares none of this, so this switches to it
# at runtime and back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'mkcp: [compose/mkcp.yaml]' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

transports() { # <count>: the measure task's transports, each with how many got through
  local out
  out=$(sudo morzer task run measure --output -- "$1" 2>&1) || die "measure failed: ${out}"
  sed -n '/^{/,/^}/p' <<<"${out}" | jq -c '.transports | map_values(.ok)'
}

sudo morzer config set installation.profile=mkcp >/dev/null || die "could not switch to the mkcp profile"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under mkcp: ${out}"
got=$(transports 3)
jq -e 'keys == ["mkcp", "reality"] and .mkcp >= 1' <<<"${got}" >/dev/null || die "measure under mkcp: ${got}"
echo "31-mkcp.sh: under mkcp the canary gets through mKCP too: ${got}"

sudo morzer config unset installation.profile >/dev/null || die "could not go back to no profile"
got=$(transports 1)
jq -e 'keys == ["reality"]' <<<"${got}" >/dev/null || die "measure after going back: ${got}"
echo "31-mkcp.sh: back to no profile, the canary checks REALITY alone"
