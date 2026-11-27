#!/usr/bin/env bash
# The entry-check task, under own-site,mkcp,hysteria2,http-origin (relay.test,
# Caddy's own CA):
#
# - the stand-in server group s1 live, and REALITY, XHTTP through the site,
#   mKCP and Hysteria2 each get through end to end, as s1's checker, a line
#   each, <entry>@s1;
# - with s1's server stopped, s1's line says it is down, and its entries
#   are not tried;
# - the door's log of the last hour tells a door no request reached, one
#   refusing every request from Docker's own address (the rig's own request
#   reaches the door through docker-proxy, as a CDN's over IPv6 does), and
#   one passing requests on to Xray;
# - that log holds addresses and statuses alone: no path, so not the CDN's.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
restore() {
  sudo morzer config unset http_origin_from >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
}
trap restore EXIT
check() { sudo morzer task run entry-check --output 2>&1 || true; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8880$1" || true; }

# Settings and parameters go in separate calls: morzer refuses them mixed.
set_config installation.domains=relay.test
set_config cert_issuer=internal http_origin_from=203.0.113.0/24
set_config installation.profile=own-site,mkcp,hysteria2,http-origin
# Xray restarts until Caddy has the site's certificate, for Hysteria2.
for _ in $(seq 20); do
  out=$(check)
  grep -Eq '^hy2@s1 +ok: ' <<<"${out}" && break
  sleep 3
done
for e in servers reality xhttp mkcp hy2; do
  grep -Eq "^${e}@s1 +ok: " <<<"${out}" || die "entry-check: ${e}@s1 is not ok: ${out}"
done
grep -Eq '^door +FAIL: no request reached the door in the last hour' <<<"${out}" ||
  die "entry-check said nothing of a door no request reached: ${out}"
echo "${0##*/}: every entry gets through end to end as s1's checker, and a door no request reached says so"

sudo docker stop relay-rig-server >/dev/null
for _ in $(seq 30); do
  out=$(check)
  grep -Eq '^servers@s1 +FAIL: s1 is down' <<<"${out}" && break
  sleep 3
done
sudo docker start relay-rig-server >/dev/null
grep -Eq '^servers@s1 +FAIL: s1 is down' <<<"${out}" || die "with s1's server stopped, entry-check does not say s1 is down: ${out}"
! grep -Eq '^(reality|xhttp|mkcp|hy2)@s1 ' <<<"${out}" || die "entry-check tried s1's entries with s1 down: ${out}"
for _ in $(seq 30); do
  out=$(check)
  grep -Eq '^reality@s1 +ok: ' <<<"${out}" && break
  sleep 3
done
grep -Eq '^reality@s1 +ok: ' <<<"${out}" || die "once s1's server is back, entry-check does not get through: ${out}"
echo "${0##*/}: with s1 down, entry-check says so and leaves its entries untried"

[ "$(code /anything)" = 404 ] || die "the door answered an address outside http_origin_from"
out=$(check)
grep -Eq '^door +FAIL: all [0-9]+ requests in the last hour refused, all from [0-9.]+, Docker.s own address' <<<"${out}" ||
  die "entry-check did not say docker-proxy hides the requests' addresses: ${out}"
echo "${0##*/}: a door refusing every request from Docker's own address says docker-proxy hides the CDN's"

set_config http_origin_from=any
path=$(sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^relay/1 ' | grep -o 'cdnpath=[^ ]*' | cut -d= -f2)
[ -n "${path}" ] || die "relay-entry gave no cdnpath"
session=$(cat /proc/sys/kernel/random/uuid)
for _ in $(seq 15); do [ "$(code "/${path}/${session}")" != 404 ] && break; sleep 2; done
for _ in $(seq 5); do
  out=$(check)
  grep -Eq '^door +ok: [1-9][0-9]* of [0-9]+ requests in the last hour went on to Xray' <<<"${out}" && break
  sleep 2
done
grep -Eq '^door +ok: ' <<<"${out}" || die "entry-check did not see the door pass a request on to Xray: ${out}"
busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
log=$(sudo docker run --rm -v dotdash-relay_door_log:/l:ro "${busybox}" cat /l/door.log)
grep -q '"remote_ip":' <<<"${log}" || die "the door's log holds no address: ${log}"
! grep -qF -e "${path}" -e "${session}" -e '"uri"' -e '"headers"' <<<"${log}" || die "the door's log holds more than addresses and statuses: ${log}"
echo "${0##*/}: a door passing requests on says so, and its log holds no path"
