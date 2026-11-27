#!/usr/bin/env bash
# Health is the relay's own machinery, never its server groups: with the
# stand-in server stopped (pre-apply/10-server.sh), doctor still passes,
# while the servers task says s1 is down and its device gets nothing; once
# the server is back, s1 is live again by itself. A malformed servers line
# keeps Xray from starting, so health fails, and config apply puts the old
# line back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
trap 'sudo docker start relay-rig-server >/dev/null 2>&1 || true; sudo docker rm -f relay-rig-alert >/dev/null 2>&1 || true' EXIT
servers() { sudo morzer task run servers --output 2>&1 || true; }
wait_for() { # <regex>: the servers task prints a matching line within 90 s
  for _ in $(seq 30); do
    out=$(servers)
    grep -Eq "$1" <<<"${out}" && return 0
    sleep 3
  done
  return 1
}
fetch() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --retry "${1:-4}" --retry-delay 2 --retry-all-errors \
    --proxy http://127.0.0.1:18085 https://www.gstatic.com/generate_204 || true
}
# 10-through.sh's phone, on a port of its own.
mkdir -p /rig/relay/alert
jq '.inbounds[0].port = 18085' /rig/relay/phone/config.json >/rig/relay/alert/config.json
chmod -R a+rX /rig/relay/alert
sudo docker run -d --name relay-rig-alert --network host -v /rig/relay/alert:/etc/xray:ro "${xray}" >/dev/null
[ "$(fetch)" = 204 ] || die "the device does not get out while the server answers"

out=$(sudo morzer doctor 2>&1) || die "doctor fails while the server answers: ${out}"
sudo docker stop relay-rig-server >/dev/null
wait_for '^s1 +down +www\.gstatic\.com down' || die "with the server stopped, the servers task does not say s1 is down: ${out}"
grep -q 'no server serves its list' <<<"${out}" || die "the servers task does not say what to look at for a group down: ${out}"
out=$(sudo morzer doctor 2>&1) || die "doctor fails with the group's server down, which is no fault of the relay's: ${out}"
[ "$(fetch 0)" != 204 ] || die "the device got out with its group's server down"
echo "${0##*/}: with the server down, doctor passes and the servers task says s1 is down"

sudo docker start relay-rig-server >/dev/null
wait_for '^s1 +live +www\.gstatic\.com ok' || die "after the server came back, s1 is not live again: ${out}"
[ "$(fetch)" = 204 ] || die "the device does not get out once the server is back"
echo "${0##*/}: once the server is back, s1 is live again by itself, and the device gets out"

# A malformed line: Xray doesn't start on it, health fails, and config
# apply puts the line before back.
if out=$(printf 'secrets:\n  servers: |\n    server/1 s1 www.gstatic.com 9443\n' | sudo morzer config apply 2>&1); then
  die "config apply took a malformed servers line"
fi
tr -s '[:space:]' ' ' <<<"${out}" | grep -qF "the relay's gateway is not working" || tr -s '[:space:]' ' ' <<<"${out}" | grep -qF 'xray is not running' ||
  die "the malformed line failed without the gateway's health check saying so: ${out}"
wait_for '^s1 +live +www\.gstatic\.com ok' || die "after the malformed line was put back, s1 is not live: ${out}"
[ "$(sudo cat /run/dotdash-relay/secrets/servers)" = "$(cat /rig/relay/server-line)" ] || die "config apply did not put the servers line back"
echo "${0##*/}: a malformed servers line fails the gateway's health check, and config apply puts the old line back"
