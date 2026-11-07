#!/usr/bin/env bash
# The canary's promise: `doctor` fails when the way out through dotdash breaks,
# on the canary's own check, and passes again once it is back. Stopping the
# stand-in server (pre-apply/10-server.sh) breaks it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer doctor 2>&1) || die "doctor fails while the server answers: ${out}"
sudo docker stop canary-rig-server >/dev/null
if out=$(sudo morzer doctor 2>&1); then
  sudo docker start canary-rig-server >/dev/null
  die "doctor passes with the server stopped"
fi
grep -qE '^ *x this machine reaches the internet through dotdash' <<<"${out}" \
  || die "doctor failed, but not on the canary's check: ${out}"
sudo docker start canary-rig-server >/dev/null
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "10-alert.sh: doctor fails while the server is down and passes once it is back"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
