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

# The relays parameter; a release from before morzer 0.15 had a secret
# instead (the benchmark rehearses the published one).
if ! sudo grep -qx '  relays:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates the relays parameter"
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

# An own-site relay that gives its XHTTP path: an XHTTP link through it too,
# over TLS under its site with its path and encryption, and an outbound.
if sudo grep -q 'dotdash-relay-\$n-xhttp' /opt/dotdash/current/tasks/client-config.sh; then
  printf '%s\n' "198.51.100.8 relay-c.test pbkC 0123456789abcdef mlkem.c own-site 00112233445566778899aabbccddeeff" |
    sudo morzer config set --set-file relays=- >/dev/null
  text=$(out)
  xlinks=$(grep '^vless://.*%5Brelay%20198.51.100.8%20xhttp%5D' <<<"${text}" || true)
  [ "$(grep -c . <<<"${xlinks}")" = "${devices}" ] || die "expected an XHTTP link through the own-site relay for each device"
  l=$(head -1 <<<"${xlinks}")
  got="$(param "$l" security) $(param "$l" type) $(param "$l" sni) $(param "$l" host) $(param "$l" path) $(param "$l" encryption)"
  [ "${got}" = "tls xhttp relay-c.test relay-c.test %2F00112233445566778899aabbccddeeff mlkem.c" ] ||
    die "the XHTTP link through the relay is not TLS under its site with its path and encryption: ${got}"
  [ "$(outbound_tags "${text}" | sort -u | tr '\n' ' ')" = "dotdash-relay-1 dotdash-relay-1-xhttp " ] ||
    die "the config lacks an XHTTP outbound through the own-site relay"
  echo "46-relays.sh: an own-site relay with its path adds an XHTTP link and outbound through it"
fi

# An own-site relay with CDNs in front (its relay-entry adds cdn=<host>,...): a
# link per CDN, to the CDN on 443 under its name with the relay's path and
# encryption, uploading by GET with the data in headers, and an outbound each.
# The same CDNs on a relay without its XHTTP path, or a malformed field: none.
if sudo grep -q 'dotdash-relay-\$n-cdn-' /opt/dotdash/current/tasks/client-config.sh; then
  printf '%s\n' \
    "198.51.100.8 relay-c.test pbkC 0123456789abcdef mlkem.c own-site 00112233445566778899aabbccddeeff cdn=cdn-a.test,cdn-b.test" \
    "198.51.100.10 site-e.test pbkE 0011223344556677 mlkem.e cdn=cdn-e.test" \
    "198.51.100.11 relay-f.test pbkF 0011223344556677 mlkem.f own-site 00112233445566778899aabbccddeeff cdn=bad_name!" |
    sudo morzer config set --set-file relays=- >/dev/null
  text=$(out)
  clinks=$(grep '^vless://.*%5Brelay%20198.51.100.8%20cdn%20' <<<"${text}" || true)
  [ "$(grep -c . <<<"${clinks}")" = $((2 * devices)) ] || die "expected a link per CDN in front of the relay for each device"
  l=$(grep -m1 'cdn%20cdn-b.test%5D$' <<<"${clinks}") || die "no link through the relay's second CDN"
  got="$(param "$l" security) $(param "$l" type) $(param "$l" sni) $(param "$l" host) $(param "$l" path) $(param "$l" encryption) $(param "$l" mode)"
  [ "${got}" = "tls xhttp cdn-b.test cdn-b.test %2F00112233445566778899aabbccddeeff mlkem.c packet-up" ] && [[ $l == *@cdn-b.test:443\?* ]] ||
    die "the link through the relay's CDN is not packet-up to the CDN with the relay's path and encryption: ${got}"
  [[ $(param "$l" extra) == *uplinkDataPlacement%22%3A%22header%22*uplinkHTTPMethod%22%3A%22GET%22* ]] ||
    die "the link through the relay's CDN does not upload by GET with the data in headers"
  ! grep -qE '%5Brelay%20198\.51\.100\.1[01]%20cdn%20' <<<"${text}" ||
    die "a relay without its XHTTP path, or with a malformed cdn= field, got CDN links"
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
    [.outbounds[] | select(.tag | startswith("dotdash-relay-1-cdn-"))] as $c
    | ($c | map(.settings.address)) == ["cdn-a.test", "cdn-b.test"]
      and ($c | all(.settings.encryption == "mlkem.c"
        and .streamSettings.xhttpSettings.path == "/00112233445566778899aabbccddeeff"
        and .streamSettings.xhttpSettings.mode == "packet-up"
        and .streamSettings.xhttpSettings.uplinkHTTPMethod == "GET"
        and .streamSettings.xhttpSettings.uplinkDataPlacement == "header"))' >/dev/null ||
    die "the config lacks a packet-up outbound per CDN in front of the relay"
  echo "46-relays.sh: CDNs in front of an own-site relay add a packet-up link and outbound each; none without its path"
fi

# A relay with mKCP (its relay-entry ends the line with kcp=<port>,<header>,
# <seed>): an mKCP link through it too, to its port with its header and seed,
# and an outbound with the same masks.
if sudo grep -q 'dotdash-relay-\$n-kcp' /opt/dotdash/current/tasks/client-config.sh; then
  printf '%s\n' "198.51.100.9 site-d.test pbkD 0011223344556677 mlkem.d kcp=9447,dtls,00112233445566778899aabbccddeeff" |
    sudo morzer config set --set-file relays=- >/dev/null
  text=$(out)
  klinks=$(grep '^vless://.*%5Brelay%20198.51.100.9%20kcp%5D' <<<"${text}" || true)
  [ "$(grep -c . <<<"${klinks}")" = "${devices}" ] || die "expected an mKCP link through the relay for each device"
  l=$(head -1 <<<"${klinks}")
  got="$(param "$l" type) $(param "$l" headerType) $(param "$l" seed) $(param "$l" encryption)"
  [ "${got}" = "kcp dtls 00112233445566778899aabbccddeeff mlkem.d" ] && [[ $l == *@198.51.100.9:9447\?* ]] ||
    die "the mKCP link through the relay is not to its port with its header, seed and encryption: ${got}"
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
    [.outbounds[] | select(.tag == "dotdash-relay-1-kcp")] as $k
    | ($k | length) == 1 and $k[0].settings.port == 9447 and $k[0].settings.address == "198.51.100.9"
      and $k[0].streamSettings == {network: "kcp", finalmask: {udp: [
        {type: "mkcp-legacy", settings: {value: "00112233445566778899aabbccddeeff"}},
        {type: "mkcp-legacy", settings: {header: "dtls"}}]}}' >/dev/null ||
    die "the config lacks an mKCP outbound through the relay with its port and masks"
  echo "46-relays.sh: a relay with mKCP adds an mKCP link and outbound through it"

  # The same relay advertising the QUIC opener (a fourth kcp= field): the relay
  # link drops headerType and seed for the whole mask list in fm=, that list
  # carries the noise mask, and so does the outbound.
  if sudo grep -q 'kopen=' /opt/dotdash/current/tasks/client-config.sh; then
    printf '%s\n' "198.51.100.9 site-d.test pbkD 0011223344556677 mlkem.d kcp=9447,dtls,00112233445566778899aabbccddeeff,quic" |
      sudo morzer config set --set-file relays=- >/dev/null
    text=$(out)
    l=$(grep -m1 '^vless://.*%5Brelay%20198.51.100.9%20kcp%5D' <<<"${text}") || die "no opener relay mKCP link"
    { [ -z "$(param "$l" headerType)" ] && [ -z "$(param "$l" seed)" ] && [ -n "$(param "$l" fm)" ]; } \
      || die "the opener relay mKCP link does not carry the mask in fm="
    printf '%s' "$(param "$l" fm)" \
      | sed 's/%7B/{/g;s/%7D/}/g;s/%22/"/g;s/%3A/:/g;s/%2C/,/g;s/%5B/[/g;s/%5D/]/g;s/%20/ /g;s/%25/%/g' \
      | jq -e '.udp | map(.type) | index("noise")' >/dev/null || die "the opener relay link's fm= has no noise mask"
    awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
      [.outbounds[] | select(.tag == "dotdash-relay-1-kcp")][0].streamSettings.finalmask.udp
      | map(.type) | index("noise")' >/dev/null || die "the opener relay mKCP outbound lacks the noise mask"
    echo "46-relays.sh: a relay advertising the opener carries the mask in fm= through it"
  fi
fi

sudo morzer config unset relays >/dev/null
[ -z "$(relay_links "$(out)")" ] || die "relay links remain once relays is unset"
echo "46-relays.sh: a link and an outbound per relay and device, none with relays unset"
