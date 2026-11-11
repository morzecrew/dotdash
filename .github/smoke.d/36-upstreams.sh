#!/usr/bin/env bash
# Two lines in the upstreams secret: the rig's upstream, which reaches the real
# sites, then a stand-in that connects everything it is asked for to the rig's
# target, which answers "ok" with 200. Which one carried a fetch of
# http://1.1.1.1/ shows in its status: the real site's 301 through the
# upstream, the target's 200 through the stand-in. An address, not a name:
# through the stand-in, DoH reaches the target too, and resolves nothing.
#
# - failover, both up: connections leave through the first line;
# - with it stopped, they move to the second within the probes' interval, and
#   doctor passes; with it back, they return to it;
# - balance: connections leave through both;
# - upstream_pin=backup: the second line goes first;
# - with the second line gone from the list, the gate has one way out again.
#
# Needs the internet, as the upstream's way to 1.1.1.1.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  - name: upstreams$' /opt/dotdash/current/secrets.schema.yaml; then
  echo "${0##*/}: skipped, the installed release predates the upstreams list"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
pass=$(random)
mkdir -p /rig/backup
jq -n --arg pass "${pass}" '{log: {loglevel: "warning"},
  inbounds: [{listen: "0.0.0.0", port: 8080, protocol: "http", settings: {accounts: [{user: "rigb", pass: $pass}]}}],
  outbounds: [{protocol: "freedom", settings: {redirect: "11.99.0.10:8000"}}]}' >/rig/backup/upstream.json
chmod -R a+rX /rig/backup
sudo docker rm -f dotdash-rig-backup >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-backup --network dotdash-rig -p 18082:8080 \
  -v /rig/backup:/etc/xray:ro "${xray}" >/dev/null

one="http://$(cat /rig/upstream.conn) name=rig"
two="http://rigb:${pass}@${host}:18082 name=backup"
list() { printf '%s\n' "$@" | sudo morzer secret set upstreams >/dev/null; }
restore() {
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo morzer config unset upstream_mode upstream_pin >/dev/null 2>&1 || true
  list "${one}" || true
  sudo docker rm -f dotdash-rig-backup >/dev/null 2>&1 || true
}
trap restore EXIT

list "${one}" "${two}"

code() { # through 10-clients.sh's REALITY client: 301 through the upstream, 200 through the stand-in
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --socks5-hostname 127.0.0.1:11080 http://1.1.1.1/ 2>/dev/null || true
}
becomes() { # <code>: whether fetches answer with it within the probes' interval and some
  local _
  for _ in $(seq 30); do [ "$(code)" = "$1" ] && return 0; sleep 3; done
  return 1
}

becomes 301 || die "failover, both up: connections do not leave through the first line (last: $(code))"
echo "${0##*/}: failover, both up: connections leave through the first line"

sudo docker stop dotdash-rig-upstream >/dev/null
becomes 200 || die "with the first line stopped, connections do not move to the second (last: $(code))"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the second line carrying: $(sudo morzer doctor 2>&1 | tail -3)"
echo "${0##*/}: with the first line stopped, connections move to the second, and doctor passes"

sudo docker start dotdash-rig-upstream >/dev/null
becomes 301 || die "once the first line is back, connections do not return to it (last: $(code))"
echo "${0##*/}: with the first line back, connections return to it"

sudo morzer config set upstream_mode=balance >/dev/null || die "could not set upstream_mode=balance"
seen=" "
for _ in $(seq 20); do
  c=$(code)
  case ${seen} in *" ${c} "*) ;; *) seen+="${c} " ;; esac
  case ${seen} in *" 301 "*" 200 "* | *" 200 "*" 301 "*) break ;; esac
done
case ${seen} in *" 301 "*" 200 "* | *" 200 "*" 301 "*) ;; *) die "balance: 20 connections did not leave through both lines (saw:${seen})" ;; esac
echo "${0##*/}: balance: connections leave through both lines"

sudo morzer config set upstream_mode=failover upstream_pin=backup >/dev/null || die "could not pin the second line"
becomes 200 || die "upstream_pin=backup: connections do not leave through the pinned line (last: $(code))"
for _ in 1 2 3; do [ "$(code)" = 200 ] || die "upstream_pin=backup: a connection left through the other line"; done
echo "${0##*/}: upstream_pin moves the named line first"

sudo morzer config unset upstream_pin >/dev/null || die "could not unset upstream_pin"
list "${one}"
sudo docker stop dotdash-rig-backup >/dev/null
becomes 301 || die "with one line again, connections do not leave through it (last: $(code))"
echo "${0##*/}: with one line, the gate has one way out"
