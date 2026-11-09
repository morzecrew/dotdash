#!/usr/bin/env bash
# The subscription refreshes through dotdash: with a short
# subscription_interval, the stand-in subscription server (pre-apply/
# 10-server.sh) logs a fetch from the stand-in dotdash server's address. The
# fetch at install, with no links to go through yet, came directly; the
# install would not have got out otherwise (10-rules.sh).
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

server=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-rig-server)
[ -n "${server}" ] || die "the stand-in server has no address"
through() { sudo docker logs client-rig-sub 2>&1 | grep -cF "${server}:" || true; }

before=$(through)
sudo morzer config set subscription_interval=5 >/dev/null
for _ in $(seq 30); do
  [ "$(through)" -gt "${before}" ] && break
  sleep 2
done
[ "$(through)" -gt "${before}" ] || die "no fetch of the subscription came through dotdash"
sudo morzer config unset subscription_interval >/dev/null
echo "15-refresh.sh: the subscription refreshes through dotdash"
