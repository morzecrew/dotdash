#!/usr/bin/env bash
# The xhttp-reality profile: the canary checks XHTTP with REALITY beside
# REALITY, against the stand-in server's 8443 (pre-apply/10-server.sh). CI
# installs no profile, and a published release that declares none of this, so
# this switches to it at runtime and back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'xhttp-reality:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

transports() { # <count>: the measure task's transports, each with how many got through
  local out
  out=$(sudo morzer task run measure --output -- "$1" 2>&1) || die "measure failed: ${out}"
  sed -n '/^{/,/^}/p' <<<"${out}" | jq -c '.transports | map_values(.ok)'
}

sudo morzer config set installation.profile=xhttp-reality >/dev/null \
  || die "could not switch to the xhttp-reality profile"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under xhttp-reality: ${out}"
got=$(transports 3)
jq -e 'keys == ["reality", "xhttp-reality"] and .["xhttp-reality"] >= 1' <<<"${got}" >/dev/null \
  || die "measure under xhttp-reality: ${got}"
echo "30-xhttp-reality.sh: under xhttp-reality the canary gets through XHTTP with REALITY too: ${got}"

sudo morzer config unset installation.profile >/dev/null || die "could not go back to no profile"
got=$(transports 1)
jq -e 'keys == ["reality"]' <<<"${got}" >/dev/null || die "measure after going back: ${got}"
echo "30-xhttp-reality.sh: back to no profile, the canary checks REALITY alone"
