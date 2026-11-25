#!/usr/bin/env bash
# The http-origin profile's door, beside own-site (relay.test, Caddy's own CA):
#
# - relay-entry prints the door's port and the xhttpSettings for the CDN's
#   form before http_origin_host is set, and asks for that name;
# - with http_origin_host set, the line ends in origin=, and the settings'
#   path is the line's cdnpath;
# - the door passes the CDNs' path on to Xray for an address in
#   http_origin_from, answers any other path with a 404, and answers nobody
#   with http_origin_from=none.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^      http-origin:' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates the http-origin profile"
  exit 0
fi

set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
restore() {
  sudo morzer config unset http_origin_host http_origin_from >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
}
trap restore EXIT
entry() { sudo morzer task run relay-entry --output -- 127.0.0.1; }
# code <path>: the door's HTTP status for a GET of that path; Xray holds a
# download open, so curl's timeout ends it after the status has come.
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8880$1" || true; }

# Settings and parameters go in separate calls: morzer refuses them mixed.
set_config installation.domains=relay.test
set_config cert_issuer=internal http_origin_from=any
set_config installation.profile=own-site,http-origin
out=$(entry)
grep -q '^8880 (http_origin_port)' <<<"${out}" || die "relay-entry did not print the door's port: ${out}"
grep -qF '"uplinkChunkSize": 4096' <<<"${out}" || die "relay-entry did not print the door's xhttpSettings: ${out}"
grep -q 'Then set http_origin_host' <<<"${out}" || die "relay-entry did not ask for http_origin_host: ${out}"
echo "${0##*/}: relay-entry prints the door's port and settings, and asks for the CDN's name"

set_config http_origin_host=cdn-door.test
out=$(entry)
line=$(grep -m1 '^127\.0\.0\.1 ' <<<"${out}" || true)
grep -q ' origin=cdn-door\.test' <<<"${line}" || die "the line does not end in origin=: ${line}"
path=$(grep -o 'cdnpath=[^ ]*' <<<"${line}" | cut -d= -f2)
[ -n "${path}" ] || die "the line carries no cdnpath: ${line}"
grep -qF "\"path\": \"/${path}\"" <<<"${out}" || die "the settings' path is not the line's cdnpath /${path}: ${out}"
! grep -q 'Then set http_origin_host' <<<"${out}" || die "relay-entry still asks for http_origin_host"
echo "${0##*/}: with http_origin_host set, the line ends in origin=, and the settings take its cdnpath"

session=$(cat /proc/sys/kernel/random/uuid)
for _ in $(seq 15); do [ "$(code "/${path}/${session}")" = 200 ] && break; sleep 2; done
[ "$(code "/${path}/${session}")" = 200 ] || die "the door did not pass the CDNs' path on to Xray: $(code "/${path}/${session}")"
[ "$(code /elsewhere)" = 404 ] || die "the door answered a path other than the CDNs': $(code /elsewhere)"
set_config http_origin_from=none
[ "$(code "/${path}/${session}")" = 404 ] || die "with http_origin_from=none, the door still answered"
echo "${0##*/}: the door passes the CDNs' path alone, to the addresses in http_origin_from alone"
