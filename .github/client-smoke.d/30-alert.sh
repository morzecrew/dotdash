#!/usr/bin/env bash
# The client's promise: `doctor` fails when the way out through dotdash breaks,
# on the client's own check, and passes again once it is back. Stopping the
# stand-in server (pre-apply/10-server.sh) breaks it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer doctor 2>&1) || die "doctor fails while the server answers: ${out}"
sudo docker stop client-rig-server >/dev/null
if out=$(sudo morzer doctor 2>&1); then
  sudo docker start client-rig-server >/dev/null
  die "doctor passes with the server stopped"
fi
grep -qF 'cannot reach the internet through dotdash' <<<"${out}" \
  || die "doctor failed, but not on the canary's check: ${out}"
sudo docker start client-rig-server >/dev/null
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "10-alert.sh: doctor fails while the server is down and passes once it is back"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
