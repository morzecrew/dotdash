#!/usr/bin/env bash
# The relay's promise: `doctor` fails when the way on to dotdash breaks,
# on the relay's own check, and passes again once it is back. Stopping the
# stand-in server (pre-apply/10-server.sh) breaks it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer doctor 2>&1) || die "doctor fails while the server answers: ${out}"
sudo docker stop relay-rig-server >/dev/null
if out=$(sudo morzer doctor 2>&1); then
  sudo docker start relay-rig-server >/dev/null
  die "doctor passes with the server stopped"
fi
# doctor wraps long lines, so the message is matched with its spaces folded.
tr -s '[:space:]' ' ' <<<"${out}" | grep -qF 'cannot reach the internet through dotdash' \
  || die "doctor failed, but not on the relay's check: ${out}"
sudo docker start relay-rig-server >/dev/null
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "10-alert.sh: doctor fails while the server is down and passes once it is back"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
