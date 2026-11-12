#!/usr/bin/env bash
# IPv6 through lines of its own (ipv6=separate, a group=ipv6 line in the
# upstreams secret). The rig has no IPv6, so a
# stand-in IPv6 proxy connects everything it is asked for to the rig's
# target, which answers "ok"; the first upstream reaches the real sites. Which
# one carried a fetch shows in its answer. (Xray writes its access log late,
# so it cannot tell.) With the IPv6 line set:
#
# - a name with an IPv6 address only, an IPv6 literal, and a name with both
#   (IPv6 preferred) leave through the IPv6 proxy, and a name with an IPv4
#   address only through the first upstream;
# - healthy, the egress check fetches through both;
# - with the IPv6 line stopped, IPv6 destinations fail rather than fall back
#   to the first upstream, IPv4 ones still work, and doctor names the IPv6
#   proxy; a wrong password there, and doctor names its credentials.
#
# That the IPv6 proxy is handed addresses only is the policy hook's to check
# (25-policy.sh). Needs the internet: names are resolved over DoH.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  - name: upstreams$' /opt/dotdash/current/secrets.schema.yaml; then
  echo "${0##*/}: skipped, the installed release predates the upstreams list"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
log6=/rig/upstream6-log/access.log
pass6=$(random)
mkdir -p /rig/upstream6 /rig/upstream6-log
chmod 0777 /rig/upstream6-log
# Xray creates the log as its own user; one left by root it cannot open.
rm -f "${log6}"
jq -n --arg pass "${pass6}" '{log: {access: "/log/access.log", loglevel: "warning"},
  inbounds: [{listen: "0.0.0.0", port: 8080, protocol: "http", settings: {accounts: [{user: "rig6", pass: $pass}]}}],
  outbounds: [{protocol: "freedom", settings: {redirect: "11.99.0.10:8000"}}]}' >/rig/upstream6/upstream.json
chmod -R a+rX /rig/upstream6
sudo docker rm -f dotdash-rig-upstream6 >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-upstream6 --network dotdash-rig -p 18081:8080 \
  -v /rig/upstream6:/etc/xray:ro -v /rig/upstream6-log:/log "${xray}" >/dev/null
for _ in $(seq 20); do [ -e "${log6}" ] && break; sleep 0.5; done
[ -e "${log6}" ] || die "the stand-in IPv6 proxy did not start: $(sudo docker logs dotdash-rig-upstream6 2>&1 | tail -1)"

one="http://$(cat /rig/upstream.conn) name=rig"
list() { printf '%s\n' "$@" | sudo morzer secret set upstreams >/dev/null; }
restore() {
  sudo docker start dotdash-rig-upstream6 >/dev/null 2>&1 || true
  sudo morzer config unset ipv6 >/dev/null 2>&1 || true
  list "${one}" || true
  sudo docker rm -f dotdash-rig-upstream6 >/dev/null 2>&1 || true
}
trap restore EXIT

list "${one}" "http://rig6:${pass6}@${host}:18081 name=rig6 group=ipv6"
sudo morzer config set ipv6=separate >/dev/null \
  || die "could not turn on ipv6=separate (its health check failed?)"

body() { # <url>: through 10-clients.sh's REALITY client; the body, or nothing
  curl -s --max-time 20 --retry 2 --retry-delay 2 --socks5-hostname 127.0.0.1:11080 "$1" 2>/dev/null || true
}
# A few tries each: right after a restart, a lookup that is not answered in
# time leaves Xray matching the name instead of its addresses, so the first
# fetch of a name may take the other way; the answer is cached for the next.
via6() { # <url> <what>
  local _
  for _ in 1 2 3; do [ "$(body "$1")" = ok ] && return 0; sleep 2; done
  die "$2 did not leave through the IPv6 line"
}
via4() { # <url> <what>
  local _ got
  for _ in 1 2 3; do
    got=$(body "$1")
    [ -n "${got}" ] && [ "${got}" != ok ] && return 0
    sleep 2
  done
  die "$2 did not leave through the first upstream"
}
via6 http://ipv6.google.com/ "a name with an IPv6 address only"
via6 'http://[2001:4860:4860::8888]/' "an IPv6 literal"
via6 http://www.google.com/ "a name with both addresses"
via4 http://ipv4.google.com/ "a name with an IPv4 address only"
echo "${0##*/}: IPv6 destinations, and names with both, leave through the IPv6 line, IPv4-only ones through the first"

sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with both lines answering"
echo "${0##*/}: the egress check passes through both lines"

sudo docker stop dotdash-rig-upstream6 >/dev/null
[ -z "$(body http://ipv6.google.com/)" ] || die "an IPv6 destination got an answer with the IPv6 line stopped"
via4 http://ipv4.google.com/ "with the IPv6 line stopped, a name with an IPv4 address only"
# doctor wraps its lines; one line each to match against.
doctor() { { sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' '; }
out=$(doctor)
grep -qE 'IPv6 lines: rig6: cannot connect to|IPv6 lines: rig6 at [^ ]+ does not answer' <<<"${out}" \
  || die "doctor does not name the IPv6 line with it stopped: ${out}"
sudo docker start dotdash-rig-upstream6 >/dev/null
echo "${0##*/}: with the IPv6 line stopped, IPv6 fails without falling back, IPv4 works, and doctor names it"

list "${one}" "http://rig6:wrong@${host}:18081 name=rig6 group=ipv6"
out=$(doctor)
grep -q 'rig6 at [^ ]* refused the credentials in its line' <<<"${out}" \
  || die "doctor does not name the IPv6 line's credentials: ${out}"
list "${one}" "http://rig6:${pass6}@${host}:18081 name=rig6 group=ipv6"
echo "${0##*/}: a wrong IPv6 line password, and doctor names its credentials"
