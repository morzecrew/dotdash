#!/usr/bin/env bash
# The servers task, and a server group of several servers. A group's
# server/1 line names each of its servers, which share their keys: the relay
# makes a way to each, and the group stays live while one serves its list.
# The rig's one stand-in can't stand behind two names, so the second is an
# address nothing answers on (TEST-NET-1): the task names it down, the group
# live, and the device still gets out. Then the rig's own line is back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

line=$(cat /rig/relay/server-line)
restore() { printf '%s\n' "${line}" | sudo morzer secret set servers >/dev/null; }
trap restore EXIT
servers() { sudo morzer task run servers --output 2>&1 || true; }
fetch() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --proxy http://127.0.0.1:18081 https://www.gstatic.com/generate_204 || true
}
# wait_for <regex>: the servers task prints a matching line within 90 s.
wait_for() {
  for _ in $(seq 30); do
    out=$(servers)
    grep -Eq "$1" <<<"${out}" && return 0
    sleep 3
  done
  return 1
}

wait_for '^s1 +live +www\.gstatic\.com ok [0-9]+ ms; 1 devices, digest [0-9a-f]{8}, list [0-9]+ s old$' ||
  die "the servers task does not say s1 is live with one device: ${out}"
grep -q '^gateway: last round [0-9]* s ago$' <<<"${out}" || die "the servers task does not say when the last round was: ${out}"
echo "${0##*/}: the servers task says s1 is live, its server answering, with one device"

# shellcheck disable=SC2086 # one field per word
set -- ${line}
two="$1 $2 $3,a.invalid $4 $5 $6 $7 $8 $9 ${10},192.0.2.1"
printf '%s\n' "${two}" | sudo morzer secret set servers >/dev/null || die "could not set a line of two servers"
wait_for '^s1 +live +www\.gstatic\.com ok [0-9]+ ms, a\.invalid down ' ||
  die "with a second server that doesn't answer, s1 is not live with it down: ${out}"
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
sudo docker run -d --name relay-rig-phone2 --network host -v /rig/relay/phone:/etc/xray:ro "${xray}" >/dev/null
code=$(fetch)
sudo docker rm -f relay-rig-phone2 >/dev/null
[ "${code}" = 204 ] || die "with one of two servers down, the device got ${code}, not 204"
echo "${0##*/}: a group of two servers, one down, stays live, and its device gets out"
restore
trap - EXIT
wait_for '^s1 +live +www\.gstatic\.com ok [0-9]+ ms;' || die "back on the rig's own line, s1 is not live: ${out}"
