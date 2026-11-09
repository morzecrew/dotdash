#!/usr/bin/env bash
# Relays (the relays parameter, filled from dotdash-relay's relay-entry task).
# With none set, client-config prints no relay link and its
# config no relay outbound. With two relay lines and a comment, every device
# gets a REALITY link per relay, to the relay's host on 443 under its site,
# with its keys and the device's own id, and the config an outbound per relay
# in the balancer. Unsetting it removes them. dotdash-relay's own smoke
# test proves a device gets through a relay.
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'relay-config' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

out() { sudo morzer task run client-config --output -- --full; }
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
relay_links() { grep '^vless://.*%5Brelay%20' <<<"$1" || true; }
outbound_tags() { awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"$1" |
  jq -r '.outbounds[].tag' | grep '^dotdash-relay-' || true; }

text=$(out)
[ -z "$(relay_links "${text}")" ] || die "client-config prints relay links with no relays set"
[ -z "$(outbound_tags "${text}")" ] || die "the config has relay outbounds with no relays set"
# One id per device, however many servers the links cover.
ids=$(grep '^vless://.*%5Breality%5D' <<<"${text}" | while read -r l; do id "$l"; done | sort -u)
devices=$(grep -c . <<<"${ids}")

printf '# two relays\n%s\n\n%s\n' \
  "relay-a.test site-a.test pbkA 0011223344556677 mlkem.a" \
  "198.51.100.7 site-b.test pbkB 8899aabbccddeeff mlkem.b" | sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
links=$(relay_links "${text}")
[ "$(grep -c . <<<"${links}")" = $((2 * devices)) ] \
  || die "expected a relay link per relay for each of ${devices} devices"
while read -r l; do
  grep -qxF "$(id "$l")" <<<"${ids}" || die "a relay link carries an id that is no device's"
  case $l in
    *@relay-a.test:443\?*) want="site-a.test pbkA 0011223344556677 mlkem.a" ;;
    *@198.51.100.7:443\?*) want="site-b.test pbkB 8899aabbccddeeff mlkem.b" ;;
    *) die "a relay link goes to neither relay's host on 443" ;;
  esac
  got="$(param "$l" sni) $(param "$l" pbk) $(param "$l" sid) $(param "$l" encryption)"
  [ "${got}" = "${want}" ] || die "a relay link's sni, pbk, sid or encryption is not its relay's"
  [ "$(param "$l" flow)" = xtls-rprx-vision ] && [ "$(param "$l" security)" = reality ] \
    || die "a relay link is not REALITY with Vision"
done <<<"${links}"
[ "$(outbound_tags "${text}" | sort -u | tr '\n' ' ')" = "dotdash-relay-1 dotdash-relay-2 " ] \
  || die "the config lacks an outbound per relay"

sudo morzer config unset relays >/dev/null
[ -z "$(relay_links "$(out)")" ] || die "relay links remain once relays is unset"
echo "46-relays.sh: a link and an outbound per relay and device, none with relays unset"
