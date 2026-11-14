#!/usr/bin/env bash
# The facts task, which an authority reads before every fleet publish: what
# the canary watches, whether each transport gets through, and with
# control_url set, whether the canary's own network answers without dotdash.
# Stopping the stand-in server (pre-apply/10-server.sh) fails REALITY.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  facts:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

facts() {
  local out
  out=$(sudo morzer task run facts --output 2>&1) || die "facts failed: ${out}"
  grep -m1 '^{' <<<"${out}"
}

got=$(facts)
jq -e '.server == "www.gstatic.com" and (.address | length > 0) and (.checked_at | type == "number")
  and .internet == null and .paths == {reality: true}' <<<"${got}" >/dev/null ||
  die "facts with the server up: ${got}"

sudo morzer config set control_url=https://www.gstatic.com/generate_204 >/dev/null || die "could not set control_url"
got=$(facts)
jq -e '.internet == true' <<<"${got}" >/dev/null || die "facts with control_url set: ${got}"
echo "25-facts.sh: ${got}"

sudo docker stop canary-rig-server >/dev/null
got=$(facts) || true
sudo docker start canary-rig-server >/dev/null
jq -e '.internet == true and .paths == {reality: false}' <<<"${got}" >/dev/null ||
  die "facts with the server stopped: ${got}"
sudo morzer config unset control_url >/dev/null || die "could not unset control_url"
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "25-facts.sh: with the server stopped, REALITY does not get through and the network still answers"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
