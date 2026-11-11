#!/usr/bin/env bash
# ipv6=block: no IPv6 destination leaves.
#
# - Xray's config asks DNS for A records only, hands the upstream IPv4
#   addresses only, and blocks ::/0 (what is left: IPv6 literals);
# - a dual-stack site still answers, and the rig's upstream, which logs every
#   destination it is handed (pre-apply/10-rig.sh), sees an IPv4 address for
#   it and no IPv6 one;
# - back on ipv6=allow, the config is as before.
#
# Whether an IPv6 literal reaches the upstream under allow can't be seen in
# the rig, so the literal's block is the config's; a rendered config was
# checked against Xray 26.10.31 by hand (#87). Needs the internet: a public
# site over DoH.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  ipv6:$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates ipv6"
  exit 0
fi

config=/etc/dotdash/application.yaml
log=/rig/upstream-log/access.log
since() { tail -n "+$(($1 + 1))" "${log}"; }
lines() { wc -l <"${log}"; }
fetch() { # <url>: its status through 10-clients.sh's REALITY client, or 000
  curl -s -o /dev/null --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors \
    -w '%{http_code}' --socks5-hostname 127.0.0.1:11080 "$1" || true
}
restore() { sudo morzer config set ipv6=allow >/dev/null 2>&1 || true; }
trap restore EXIT

sudo jq -e '[.routing.rules[] | select(.ip == ["::/0"] and .outboundTag == "block")] == []' "${config}" >/dev/null ||
  die "IPv6 is blocked before ipv6=block is set"

sudo morzer config set ipv6=block >/dev/null || die "could not set ipv6=block"
sudo jq -e '.dns.queryStrategy == "UseIPv4"
  and ([.outbounds[] | select(.tag == "upstream")][0].targetStrategy == "ForceIPv4")
  and ([.routing.rules[] | select(.ip == ["::/0"])] == [{ip: ["::/0"], outboundTag: "block"}])
  and .routing.rules[-1] == {network: "tcp,udp", outboundTag: "upstream"}' "${config}" >/dev/null ||
  die "ipv6=block did not render A-only DNS, an IPv4-only upstream and the ::/0 block: $(sudo jq -c '{dns: .dns.queryStrategy, rules: .routing.rules}' "${config}")"
echo "${0##*/}: ipv6=block asks DNS for IPv4 only, hands the upstream IPv4 only, and blocks ::/0"

mark=$(lines)
code=$(fetch https://www.gstatic.com/generate_204)
[ "${code}" = 204 ] || die "a dual-stack site gave ${code} with ipv6=block, not 204"
seen=""
for _ in $(seq 20); do
  seen=$(since "${mark}")
  grep -qE 'accepted //[0-9]+(\.[0-9]+){3}:443' <<<"${seen}" && break
  sleep 1
done
grep -qE 'accepted //[0-9]+(\.[0-9]+){3}:443' <<<"${seen}" || die "the upstream's log shows no IPv4 address for the site"
! grep -qF 'accepted //[' <<<"${seen}" || die "the upstream was handed an IPv6 address with ipv6=block: $(grep -F 'accepted //[' <<<"${seen}" | head -2)"
echo "${0##*/}: with ipv6=block a dual-stack site answers, over IPv4 alone"

sudo morzer config set ipv6=allow >/dev/null || die "could not set ipv6=allow"
sudo jq -e '.dns.queryStrategy == "UseIP"
  and ([.routing.rules[] | select(.ip == ["::/0"] and .outboundTag == "block")] == [])' "${config}" >/dev/null ||
  die "back on ipv6=allow, the IPv6 block remains"
code=$(fetch https://www.gstatic.com/generate_204)
[ "${code}" = 204 ] || die "back on ipv6=allow, the site gave ${code}"
echo "${0##*/}: back on ipv6=allow, the config is as before"
