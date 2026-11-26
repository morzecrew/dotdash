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

out() { sudo morzer task run client-config --output -- --full; }
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
# Links are named "<route> · <transport>", percent-encoded: through a relay
# "relay[ <n>] · reality", "· xhttp", "· cdn[ <m>]" and so on, numbered only
# where there are several.
relay_links() { grep -E '^vless://.*#relay(%20[0-9]+)?%20%C2%B7%20' <<<"$1" || true; }
outbound_tags() { awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"$1" |
  jq -r '.outbounds[].tag' | grep -E '^dotdash-(cdn-)?relay-' || true; }

text=$(out)
[ -z "$(relay_links "${text}")" ] || die "client-config prints relay links with no relays set"
[ -z "$(outbound_tags "${text}")" ] || die "the config has relay outbounds with no relays set"
# One id per device, however many servers the links cover.
ids=$(grep -E '^vless://.*#server(%20[0-9]+)?%20%C2%B7%20reality$' <<<"${text}" | while read -r l; do id "$l"; done | sort -u)
devices=$(grep -c . <<<"${ids}")

printf '# two relays\n%s\n\n%s\n' \
  "relay-a.test site-a.test pbkA000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.a" \
  "198.51.100.7 site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b" | sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
links=$(relay_links "${text}")
[ "$(grep -c . <<<"${links}")" = $((2 * devices)) ] \
  || die "expected a relay link per relay for each of ${devices} devices"
while read -r l; do
  grep -qxF "$(id "$l")" <<<"${ids}" || die "a relay link carries an id that is no device's"
  case $l in
    *@relay-a.test:443\?*) want="site-a.test pbkA000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.a" no=1 ;;
    *@198.51.100.7:443\?*) want="site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b" no=2 ;;
    *) die "a relay link goes to neither relay's host on 443" ;;
  esac
  [[ $l == *"#relay%20${no}%20%C2%B7%20reality" ]] || die "a relay link is not named by its relay's place, relay ${no}, and no host"
  got="$(param "$l" sni) $(param "$l" pbk) $(param "$l" sid) $(param "$l" encryption)"
  [ "${got}" = "${want}" ] || die "a relay link's sni, pbk, sid or encryption is not its relay's"
  [ "$(param "$l" flow)" = xtls-rprx-vision ] && [ "$(param "$l" security)" = reality ] \
    || die "a relay link is not REALITY with Vision"
done <<<"${links}"
[ "$(outbound_tags "${text}" | sort -u | tr '\n' ' ')" = "dotdash-relay-1 dotdash-relay-2 " ] \
  || die "the config lacks an outbound per relay"

# An own-site relay that gives its XHTTP path: an XHTTP link through it too,
# over TLS under its site with its path and encryption, and an outbound.
printf '%s\n' "198.51.100.8 relay-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
xlinks=$(grep '^vless://.*#relay%20%C2%B7%20xhttp$' <<<"${text}" || true)
[ "$(grep -c . <<<"${xlinks}")" = "${devices}" ] || die "expected an XHTTP link through the own-site relay for each device"
l=$(head -1 <<<"${xlinks}")
got="$(param "$l" security) $(param "$l" type) $(param "$l" sni) $(param "$l" host) $(param "$l" path) $(param "$l" encryption)"
[ "${got}" = "tls xhttp relay-c.test relay-c.test %2F00112233445566778899aabbccddeeff mlkem768x25519plus.native.0rtt.c" ] ||
  die "the XHTTP link through the relay is not TLS under its site with its path and encryption: ${got}"
[ "$(outbound_tags "${text}" | sort -u | tr '\n' ' ')" = "dotdash-relay-1 dotdash-relay-1-xhttp " ] ||
  die "the config lacks an XHTTP outbound through the own-site relay"
echo "46-relays.sh: an own-site relay with its path adds an XHTTP link and outbound through it"

# An own-site relay with CDNs in front (its relay-entry adds cdn=<host>,...): a
# link per CDN, to the CDN on 443 under its name with the relay's path and
# encryption, uploading by GET with the data in headers, and an outbound each.
# The same CDNs on a relay without its XHTTP path, or a malformed field: none.
printf '%s\n' \
  "198.51.100.8 relay-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff cdn=cdn-a.test,cdn-b.test" \
  "198.51.100.10 site-e.test pbkE000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.e cdn=cdn-e.test" \
  "198.51.100.11 relay-f.test pbkF000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.f own-site 00112233445566778899aabbccddeeff cdn=bad_name!" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
clinks=$(grep '^vless://.*#relay%201%20%C2%B7%20cdn%20[0-9]$' <<<"${text}" || true)
[ "$(grep -c . <<<"${clinks}")" = $((2 * devices)) ] || die "expected a link per CDN in front of the relay for each device"
l=$(grep -m1 '#relay%201%20%C2%B7%20cdn%202$' <<<"${clinks}") || die "no link through the relay's second CDN"
got="$(param "$l" security) $(param "$l" type) $(param "$l" sni) $(param "$l" host) $(param "$l" path) $(param "$l" encryption) $(param "$l" mode)"
[ "${got}" = "tls xhttp cdn-b.test cdn-b.test %2F00112233445566778899aabbccddeeff mlkem768x25519plus.native.0rtt.c packet-up" ] && [[ $l == *@cdn-b.test:443\?* ]] ||
  die "the link through the relay's CDN is not packet-up to the CDN with the relay's path and encryption: ${got}"
[[ $(param "$l" extra) == *uplinkDataPlacement%22%3A%22header%22*uplinkHTTPMethod%22%3A%22GET%22* ]] ||
  die "the link through the relay's CDN does not upload by GET with the data in headers"
! grep -qE '#relay%20[23]%20%C2%B7%20cdn' <<<"${text}" ||
  die "a relay without its XHTTP path, or with a malformed cdn= field, got CDN links"
awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
  [.outbounds[].tag | select(startswith("dotdash-")) | startswith("dotdash-cdn-")] as $k
  | [.outbounds[] | select(.tag | startswith("dotdash-cdn-relay-1-"))] as $c
  | ($k | .[index(true):] | all)
  and ($c | map(.settings.address)) == ["cdn-a.test", "cdn-b.test"]
    and ($c | all(.settings.encryption == "mlkem768x25519plus.native.0rtt.c"
      and .streamSettings.xhttpSettings.path == "/00112233445566778899aabbccddeeff"
      and .streamSettings.xhttpSettings.mode == "packet-up"
      and .streamSettings.xhttpSettings.uplinkHTTPMethod == "GET"
      and .streamSettings.xhttpSettings.uplinkDataPlacement == "header"))' >/dev/null ||
  die "the config lacks a packet-up outbound per CDN in front of the relay, after every other outbound"
echo "46-relays.sh: CDNs in front of an own-site relay add a packet-up link and outbound each; none without its path"

# A relay that serves its CDNs on a path of their own (its relay-entry adds
# cdnpath=<path>): its CDN links and outbounds take that path, disguised as its
# CDN inbound expects (session, sequence and padding in cookies); one whose
# cdnpath= is not hex keeps its XHTTP path, plain.
printf '%s\n' \
  "198.51.100.8 relay-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff cdn=cdn-a.test cdnpath=aabbccddeeff001122334455" \
  "198.51.100.11 relay-f.test pbkF000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.f own-site 00112233445566778899aabbccddeeff cdn=cdn-f.test cdnpath=not/hex" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
l=$(grep -m1 '#relay%201%20%C2%B7%20cdn$' <<<"${text}") || die "no link through the CDN of the relay with a CDN path"
[ "$(param "$l" path)" = "%2Faabbccddeeff001122334455" ] || die "the CDN link does not take the relay's CDN path: $(param "$l" path)"
[[ $(param "$l" extra) == *xPaddingObfsMode%22%3Atrue*sessionIDPlacement%22%3A%22cookie%22*seqPlacement%22%3A%22cookie%22* ]] ||
  die "the CDN link by the relay's CDN path is not disguised"
l=$(grep -m1 '#relay%202%20%C2%B7%20cdn$' <<<"${text}") || die "no link through the CDN of the relay with a malformed CDN path"
[ "$(param "$l" path)" = "%2F00112233445566778899aabbccddeeff" ] && [[ $(param "$l" extra) != *xPaddingObfsMode* ]] ||
  die "a relay with a malformed cdnpath= did not keep its XHTTP path, plain"
awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
  [.outbounds[] | select(.tag == "dotdash-cdn-relay-1-1")][0].streamSettings.xhttpSettings
  | .path == "/aabbccddeeff001122334455" and .xPaddingObfsMode == true and .xPaddingMethod == "tokenish"
    and .sessionIDPlacement == "cookie" and .seqPlacement == "cookie" and .uplinkDataKey == "X-Part"' >/dev/null ||
  die "the config's outbound through the relay's CDN path is not disguised"
echo "46-relays.sh: a relay's CDN path gives disguised CDN links and outbounds; a malformed one the plain path"

# A relay with mKCP (its relay-entry ends the line with kcp=<port>,<header>,
# <seed>): an mKCP link through it too, to its port with its header and seed,
# and an outbound with the same masks.
printf '%s\n' "198.51.100.9 site-d.test pbkD000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.d kcp=9447,dtls,00112233445566778899aabbccddeeff" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
klinks=$(grep '^vless://.*#relay%20%C2%B7%20kcp$' <<<"${text}" || true)
[ "$(grep -c . <<<"${klinks}")" = "${devices}" ] || die "expected an mKCP link through the relay for each device"
l=$(head -1 <<<"${klinks}")
got="$(param "$l" type) $(param "$l" headerType) $(param "$l" seed) $(param "$l" encryption)"
[ "${got}" = "kcp dtls 00112233445566778899aabbccddeeff mlkem768x25519plus.native.0rtt.d" ] && [[ $l == *@198.51.100.9:9447\?* ]] ||
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
printf '%s\n' "198.51.100.9 site-d.test pbkD000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.d kcp=9447,dtls,00112233445566778899aabbccddeeff,quic" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
l=$(grep -m1 '^vless://.*#relay%20%C2%B7%20kcp$' <<<"${text}") || die "no opener relay mKCP link"
{ [ -z "$(param "$l" headerType)" ] && [ -z "$(param "$l" seed)" ] && [ -n "$(param "$l" fm)" ]; } \
  || die "the opener relay mKCP link does not carry the mask in fm="
printf '%s' "$(param "$l" fm)" \
  | sed 's/%7B/{/g;s/%7D/}/g;s/%22/"/g;s/%3A/:/g;s/%2C/,/g;s/%5B/[/g;s/%5D/]/g;s/%20/ /g;s/%25/%/g' \
  | jq -e '.udp | map(.type) | index("noise")' >/dev/null || die "the opener relay link's fm= has no noise mask"
awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e '
  [.outbounds[] | select(.tag == "dotdash-relay-1-kcp")][0].streamSettings.finalmask.udp
  | map(.type) | index("noise")' >/dev/null || die "the opener relay mKCP outbound lacks the noise mask"
echo "46-relays.sh: a relay advertising the opener carries the mask in fm= through it"

# A cdn-only relay (its relay-entry ends the line with cdn-only): devices get
# its CDN link alone, and the config its CDN outbound alone, nothing to its own
# address; the same flag on a relay with no CDN leaves it out, so the other is
# the lone relay, named with no number.
printf '%s\n' \
  "198.51.100.12 relay-g.test pbkG000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.g own-site 00112233445566778899aabbccddeeff kcp=9447,dtls,00112233445566778899aabbccddeeff cdn=cdn-g.test cdn-only" \
  "198.51.100.13 site-h.test pbkH000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.h cdn-only" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
links=$(relay_links "${text}")
[ "$(grep -c . <<<"${links}")" = "${devices}" ] && ! grep -qv '#relay%20%C2%B7%20cdn$' <<<"${links}" ||
  die "a cdn-only relay gave devices links besides its CDN's, or one with no CDN got links"
[ "$(outbound_tags "${text}" | tr '\n' ' ')" = "dotdash-cdn-relay-1-1 " ] ||
  die "a cdn-only relay's outbounds are not its CDN's alone: $(outbound_tags "${text}" | tr '\n' ' ')"
echo "46-relays.sh: a cdn-only relay gives its CDN link and outbound alone, and one with no CDN nothing"

# A relay with Hysteria2 (own-site, whose relay-entry adds hy2=<port>): a
# Hysteria2 link through it, to that port under its site's name, and an
# outbound logging in as the device; off=hysteria2 takes both, and a relay with no
# site of its own, so no certificate, gets neither.
own="198.51.100.13 relay-h.test pbkH000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.h own-site 00112233445566778899aabbccddeeff"
printf '%s hy2=8443\n' "${own}" | sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
hlinks=$(grep '^hysteria2://.*#relay%20%C2%B7%20hy2$' <<<"${text}" || true)
[ "$(grep -c . <<<"${hlinks}")" = "${devices}" ] || die "expected a Hysteria2 link through the relay for each device"
l=$(head -1 <<<"${hlinks}")
[[ $l == hysteria2://*@198.51.100.13:8443/\?sni=relay-h.test#* ]] ||
  die "the Hysteria2 link through the relay is not to its port under its site's name"
hid=${l#hysteria2://} && hid=${hid%%@*}
awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" | jq -e --arg id "${hid}" '
  [.outbounds[] | select(.tag == "dotdash-relay-1-hy2")] as $h
  | ($h | length) == 1 and $h[0].settings == {version: 2, address: "198.51.100.13", port: 8443}
    and $h[0].streamSettings.tlsSettings == {serverName: "relay-h.test", alpn: ["h3"]}
    and $h[0].streamSettings.hysteriaSettings == {version: 2, auth: $id}
    and $h[0].streamSettings.finalmask == {quicParams: {keepAlivePeriod: 10}}' >/dev/null ||
  die "the config lacks a Hysteria2 outbound through the relay, to its port, as the device"
printf '%s hy2=8443 off=hysteria2\n' "${own}" | sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
! grep -q '#relay%20%C2%B7%20hy2$' <<<"${text}" || die "off=hysteria2 left a Hysteria2 link through the relay"
tags=$(outbound_tags "${text}")
! grep -qx dotdash-relay-1-hy2 <<<"${tags}" || die "off=hysteria2 left a Hysteria2 outbound through the relay"
printf '%s\n' "198.51.100.13 relay-h.test pbkH000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.h hy2=8443" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
! grep -q '#relay%20%C2%B7%20hy2' <<<"${text}" || die "a relay with no site of its own got a Hysteria2 link"
echo "46-relays.sh: a relay with Hysteria2 adds a link and outbound through it; off=hysteria2 and no own site leave none"

# A relay whose canaries find some paths blocked (dotdash-manager's off=):
# devices get none of those through it, and its other links as before.
printf '%s\n' "198.51.100.8 relay-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff kcp=9447,dtls,00112233445566778899aabbccddeeff off=reality,mkcp" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
! grep -q '#relay%20%C2%B7%20reality$' <<<"${text}" || die "off=reality left a REALITY link through the relay"
! grep -q '#relay%20%C2%B7%20kcp$' <<<"${text}" || die "off=mkcp left an mKCP link through the relay"
[ "$(grep -c '#relay%20%C2%B7%20xhttp$' <<<"${text}")" = "${devices}" ] ||
  die "off=reality,mkcp took the XHTTP links through the relay too"
[ "$(outbound_tags "${text}" | sort -u | tr '\n' ' ')" = "dotdash-relay-1-xhttp " ] ||
  die "under off=reality,mkcp the relay's outbounds are not its XHTTP one alone: $(outbound_tags "${text}" | tr '\n' ' ')"
echo "46-relays.sh: off=reality,mkcp leaves the relay's XHTTP link and outbound alone"

# split beside off=reality (dotdash-manager's, when the relay's canaries got
# REALITY through only with its hello split): share links still lose REALITY
# through the relay, while the Xray config keeps its REALITY outbound, split.
printf '%s\n' "198.51.100.8 relay-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff off=reality split" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
! grep -q '#relay%20%C2%B7%20reality$' <<<"${text}" || die "off=reality split left a REALITY link through the relay"
config=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}")
jq -e '[.outbounds[] | select(.tag == "dotdash-relay-1")] | length > 0
  and all(.[]; .streamSettings.finalmask.tcp[0].settings.packets == "tlshello")' <<<"${config}" >/dev/null ||
  die "under off=reality split the relay's REALITY outbound is not there, split: $(jq -c '[.outbounds[] | {tag, f: .streamSettings.finalmask}]' <<<"${config}")"
echo "46-relays.sh: split keeps the relay's REALITY outbound in the config, split, while share links lose it"

# Relays named by name= (the relay's name parameter): their links carry the
# name in place of "relay <n>"; a name an earlier relay took, or a malformed
# one, leaves the relay its number, and is reported.
printf '%s\n' \
  "relay-a.test site-a.test pbkA000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.a name=edge-1" \
  "198.51.100.7 site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b name=edge-1" \
  "198.51.100.8 site-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c name=bad/name" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
[ "$(grep -c '^vless://[^@]*@relay-a\.test:443?.*#edge-1%20%C2%B7%20reality$' <<<"${text}")" = "${devices}" ] ||
  die "a named relay's links do not carry its name"
[ "$(grep -c '^vless://[^@]*@198\.51\.100\.7:443?.*#relay%202%20%C2%B7%20reality$' <<<"${text}")" = "${devices}" ] ||
  die "a relay named as an earlier one is does not go by its number"
[ "$(grep -c '^vless://[^@]*@198\.51\.100\.8:443?.*#relay%203%20%C2%B7%20reality$' <<<"${text}")" = "${devices}" ] ||
  die "a relay with a malformed name does not go by its number"
err=$(out 2>&1 >/dev/null)
grep -qF 'relays: 198.51.100.7 is named edge-1, as an earlier relay is' <<<"${err}" ||
  die "a name an earlier relay took is not reported"
echo "46-relays.sh: a named relay's links carry its name; a taken or malformed name leaves its number"

# standby: a relay's links come last among the share links, and its
# outbounds first in the config, outside the dotdash- tags the balancer and
# the checks take, so Xray sends it only what the balancer can't place; and
# no fallback goes before it.
printf '%s\n%s\n' "relay-a.test site-a.test pbkA000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.a name=near" \
  "198.51.100.7 site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b name=far standby" |
  sudo morzer config set --set-file relays=- >/dev/null
text=$(out)
last=$(grep -E '^(vless|hysteria2)://' <<<"${text}" | tail -n 1)
[[ ${last} == *@198.51.100.7:443\?*"#far%20%C2%B7%20reality" ]] || die "a standby relay's links do not come last"
config=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}")
jq -e '.outbounds[0].tag == "standby-relay-2" and .outbounds[0].settings.address == "198.51.100.7"
  and ([.outbounds[].tag | select(startswith("dotdash-relay-2"))] | length == 0)
  and ([.outbounds[].tag] | index("dotdash-relay-1") != null)
  and .routing.balancers[0].selector == ["dotdash-"] and (.routing.balancers[0] | has("fallbackTag") | not)
  and .burstObservatory.subjectSelector == ["dotdash-"]' <<<"${config}" >/dev/null ||
  die "a standby relay's outbound is not first and outside the balancer and the checks, or a fallback goes before it"
grep -qF 'the standby relays only when none answers' <<<"${text}" || die "the config's note leaves the standby relays out"
echo "46-relays.sh: a standby relay's links come last, its outbound first and outside the balancer and the checks"

sudo morzer config unset relays >/dev/null
[ -z "$(relay_links "$(out)")" ] || die "relay links remain once relays is unset"
echo "46-relays.sh: a link and an outbound per relay and device, none with relays unset"
