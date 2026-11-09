#!/usr/bin/env bash
# The subscription refreshes through dotdash. Its URL moves to the stand-in
# subscription server's own address on the stand-in dotdash server's bridge
# (pre-apply/10-server.sh), which that server reaches and the client's
# network does not; the links stay cached from the install. With a short
# subscription_interval, the subscription server then logs a fetch from the
# stand-in dotdash server's address. The fetch at install, with no links to go
# through yet, came directly: the install would not have got out otherwise
# (10-rules.sh).
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

address() { sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$1"; }
server=$(address client-rig-server)
sub=$(address client-rig-sub)
[ -n "${server}" ] && [ -n "${sub}" ] || die "a stand-in has no address"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
through() { sudo docker logs client-rig-sub 2>&1 | grep -cF "${server}:" || true; }

before=$(through)
printf 'http://%s:8080/sub' "${sub}" | sudo morzer secret set subscription_url >/dev/null
sudo morzer config set subscription_interval=5 >/dev/null
for _ in $(seq 30); do
  [ "$(through)" -gt "${before}" ] && break
  sleep 2
done
[ "$(through)" -gt "${before}" ] || die "no fetch of the subscription came through dotdash"

printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
sudo morzer config unset subscription_interval >/dev/null
echo "15-refresh.sh: the subscription refreshes through dotdash"
