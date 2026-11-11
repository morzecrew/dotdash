#!/usr/bin/env bash
# ipv6=block: no IPv6 destination leaves. The rig's upstream logs every
# destination it is handed (pre-apply/10-rig.sh), so:
#
# - the control, ipv6=allow: an IPv6 literal goes on to the upstream;
# - ipv6=block: the same literal never reaches it, a dual-stack name is handed
#   over as an IPv4 address and still answers, and Xray's config asks DNS for
#   A records only and the upstream for IPv4 only;
# - back to ipv6=allow, the literal reaches the upstream again.
#
# The literal is a public address (geoip:private would block a documentation
# one either way); the rig has no IPv6, so nothing is reached, and the upstream
# only has to be handed it. Needs the internet: a public site over DoH.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  ipv6:$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates ipv6"
  exit 0
fi

log=/rig/upstream-log/access.log
v6=2606:4700:4700::1111
since() { tail -n "+$(($1 + 1))" "${log}"; }
lines() { wc -l <"${log}"; }
fetch() { # <url>: its status through 10-clients.sh's REALITY client, or 000
  curl -s -o /dev/null --max-time 15 -w '%{http_code}' --socks5-hostname 127.0.0.1:11080 "$1" || true
}
asked_for_v6() { # <log mark>: whether the upstream was handed the literal since
  sleep 2
  grep -qF "[${v6}]" <<<"$(since "$1")"
}
restore() { sudo morzer config set ipv6=allow >/dev/null 2>&1 || true; }
trap restore EXIT

mark=$(lines)
fetch "http://[${v6}]/" >/dev/null
asked_for_v6 "${mark}" || die "with ipv6=allow the upstream was not handed ${v6}, so the checks below would prove nothing"
echo "${0##*/}: with ipv6=allow an IPv6 literal goes on to the upstream"

sudo morzer config set ipv6=block >/dev/null || die "could not set ipv6=block"
sudo jq -e '.dns.queryStrategy == "UseIPv4"
  and ([.outbounds[] | select(.tag == "upstream")][0].targetStrategy == "ForceIPv4")
  and ([.routing.rules[] | select(.ip == ["::/0"])] == [{ip: ["::/0"], outboundTag: "block"}])' \
  /etc/dotdash/application.yaml >/dev/null ||
  die "ipv6=block did not render A-only DNS, an IPv4-only upstream and the ::/0 block"

mark=$(lines)
fetch "http://[${v6}]/" >/dev/null
! asked_for_v6 "${mark}" || die "with ipv6=block the upstream was still handed ${v6}"
mark=$(lines)
code=$(fetch https://www.gstatic.com/generate_204)
seen=$(since "${mark}")
[ "${code}" = 204 ] || die "a dual-stack site gave ${code} with ipv6=block, not 204"
grep -qE 'accepted //[0-9]+(\.[0-9]+){3}:443' <<<"${seen}" || die "the upstream shows no IPv4 address for the site"
! grep -qF 'accepted //[' <<<"${seen}" || die "the upstream was handed an IPv6 address with ipv6=block"
echo "${0##*/}: with ipv6=block the literal stops at Xray, and a dual-stack site goes out over IPv4"

sudo morzer config set ipv6=allow >/dev/null || die "could not set ipv6=allow"
mark=$(lines)
fetch "http://[${v6}]/" >/dev/null
asked_for_v6 "${mark}" || die "back on ipv6=allow, the upstream is not handed the literal again"
echo "${0##*/}: back on ipv6=allow, IPv6 goes on to the upstream again"
