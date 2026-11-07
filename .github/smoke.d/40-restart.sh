#!/usr/bin/env bash
# Clients come back by themselves after Xray restarts: `morzer restart xray`
# re-creates it, and 10-clients.sh's REALITY and XHTTP clients reach the
# target again without being touched.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

sudo morzer restart xray >/dev/null || die "morzer restart xray failed"
for port in 11080 11081; do
  curl -fsS -o /dev/null --max-time 15 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:${port}" http://target:8000/ \
    || die "the client on ${port} did not come back after Xray restarted"
done
echo "40-restart.sh: clients reconnect after Xray restarts"
