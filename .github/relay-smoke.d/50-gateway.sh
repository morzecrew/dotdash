#!/usr/bin/env bash
# The relay as a gateway to two server groups, a and b, each a stand-in
# server (an Xray of the pinned image on a host port of its own, letting the
# relay in by the id it derives from its own relay_seed and the relay's name
# and nonce) with an exit of its own (busybox httpd answering exit-a or
# exit-b, and a slow download) and a stand-in for its internal listener,
# which serves the relay's list and its devices' subscriptions. Under
# own-site,mkcp,hysteria2 (relay.test, Caddy's own CA), a device of each
# group on each transport: REALITY, XHTTP behind the site, mKCP, Hysteria2.
#
# - every device reaches its own group's exit, on every transport, and one
#   in no list gets nothing;
# - each group's subscription comes through the relay's site by its token's
#   prefix, and a prefix no list has gets the site, as any other path;
# - a device added to b's list gets in within 70 s, with no restart;
# - an id both groups list, bytes 6 and 7 aside, is dropped from both;
# - a device deleted while its download runs is cut: Xray restarts;
# - with b's server down, b's devices get nothing on any transport, and its
#   subscriptions the site, while a's are unaffected; the same after a
#   restart with b down, before the first round.
#
# No id, token or list is printed: a failure names the step.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

domain=relay.test
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
W=/rig/gw
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
restore() {
  [ -z "${slow:-}" ] || kill "${slow}" 2>/dev/null || true
  printf '%s\n' "$(cat /rig/relay/server-line)" | sudo morzer secret set servers >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  for c in client srv-a srv-b exit-a exit-b web-a web-b; do sudo docker rm -f "relay-rig-gw-${c}" >/dev/null 2>&1 || true; done
  sudo docker network rm relay-rig-gw-a relay-rig-gw-b >/dev/null 2>&1 || true
}
trap restore EXIT

# --- two stand-in groups -------------------------------------------------------

sudo rm -rf "${W}"
mkdir -p "${W}"
name=$(sudo morzer config get name)
nonce=$(sudo cat /run/dotdash-relay/secrets/nonce)
uuid() { cat /proc/sys/kernel/random/uuid; }
list() { # <group> <lines...>: the group's list for the relay, swapped in whole
  local f="${W}/$1/web/${listfile[$1]}"
  shift
  { echo "# dotdash relay list v1"; [ $# = 0 ] || printf '%s\n' "$@"; } >"${f}.new"
  chmod a+r "${f}.new"
  mv "${f}.new" "${f}"
}
declare -A listfile pbk rid
lines=
port=9451
for g in a b; do
  mkdir -p "${W}/${g}/web" "${W}/${g}/exit/cgi-bin" "${W}/${g}/server"
  keys=$(sudo docker run --rm "${xray}" x25519)
  private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
  pbk[${g}]=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
  openssl rand -hex 32 | tr -d '\n' >"${W}/${g}/seed"
  chmod a+r "${W}/${g}/seed"
  rid[${g}]=$(sudo docker run --rm -v "${W}/${g}/seed:/seed:ro" "${xray}" relay-id /seed "${name}" "${nonce}")
  listfile[${g}]=$(printf '%s:list' "${rid[${g}]}" | sha256sum | cut -c1-32)
  printf 'exit-%s' "${g}" >"${W}/${g}/exit/index.html"
  printf '#!/bin/sh\nprintf "Content-Type: text/plain\\r\\n\\r\\n"\ni=0\nwhile [ $i -lt 90 ]; do printf x; sleep 1; i=$((i + 1)); done\n' \
    >"${W}/${g}/exit/cgi-bin/slow"
  chmod a+rx "${W}/${g}/exit/cgi-bin/slow"
  jq -n --arg id "${rid[${g}]}" --arg key "${private}" --arg g "${g}" --arg name "${name}" '
    {log: {loglevel: "warning"},
     inbounds: [{listen: "0.0.0.0", port: 443, protocol: "vless",
       settings: {clients: [{id: $id, email: ("relay-" + $name), flow: "xtls-rprx-vision"}], decryption: "none"},
       streamSettings: {network: "raw", security: "reality", realitySettings:
         {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: ["0a1b"]}}}],
     outbounds: [{protocol: "freedom", settings: {redirect: ("relay-rig-gw-exit-" + $g + ":80"), finalRules: [{action: "allow"}]}},
       {tag: "sub", protocol: "freedom", settings: {redirect: ("relay-rig-gw-web-" + $g + ":8085"), finalRules: [{action: "allow"}]}},
       {tag: "block", protocol: "blackhole"}],
     routing: {rules: [{domain: ["domain:sub.dotdash.internal"], user: ["regexp:^relay-"], outboundTag: "sub"},
       {domain: ["domain:sub.dotdash.internal"], outboundTag: "block"}]}}' >"${W}/${g}/server/config.json"
  lines+="server/1 ${g} www.gstatic.com ${port} ${pbk[${g}]} 0a1b none ${rid[${g}]} address=${host}"$'\n'
  chmod -R a+rX "${W}/${g}"
  sudo docker network create "relay-rig-gw-${g}" >/dev/null
  sudo docker run -d --name "relay-rig-gw-exit-${g}" --network "relay-rig-gw-${g}" -v "${W}/${g}/exit:/www:ro" "${busybox}" \
    httpd -f -p 80 -h /www >/dev/null
  sudo docker run -d --name "relay-rig-gw-web-${g}" --network "relay-rig-gw-${g}" -v "${W}/${g}/web:/www:ro" "${busybox}" \
    httpd -f -p 8085 -h /www >/dev/null
  sudo docker run -d --name "relay-rig-gw-srv-${g}" --network "relay-rig-gw-${g}" -p "${port}:443" \
    -v "${W}/${g}/server/config.json:/etc/xray/config.json:ro" "${xray}" >/dev/null
  port=$((port + 1))
done
[ "${rid[a]}" != "${rid[b]}" ] || die "the relay has one id on two groups"
PHONE_A=$(uuid) PHONE_B=$(uuid) LAPTOP_B=$(uuid) STRANGER=$(uuid)
# PHONE_B but for bytes 6 and 7, which Xray ignores: one id to it.
DUP="${PHONE_B:0:14}4fff${PHONE_B:18}"
TOK_A=$(openssl rand -hex 16) TOK_B=$(openssl rand -hex 16)
printf 'subscription of phone@a' >"${W}/a/web/${TOK_A}"
printf 'subscription of phone@b' >"${W}/b/web/${TOK_B}"
chmod a+r "${W}/a/web/${TOK_A}" "${W}/b/web/${TOK_B}"
list a "${PHONE_A} phone ${TOK_A:0:12}"
list b "${PHONE_B} phone ${TOK_B:0:12}"

# --- the relay: its site, mKCP and Hysteria2, and the two groups ----------------

set_config "installation.domains=${domain}"
set_config cert_issuer=internal
set_config installation.profile=own-site,mkcp,hysteria2
printf '%s' "${lines}" | sudo morzer secret set servers >/dev/null || die "could not set the two groups' lines"
servers() { sudo morzer task run servers --output 2>&1 || true; }
wait_for() { # <regex> [tries]: the servers task prints a matching line, 3 s apart
  for _ in $(seq "${2:-30}"); do
    out=$(servers)
    grep -Eq "$1" <<<"${out}" && return 0
    sleep 3
  done
  return 1
}
wait_for '^a +live ' && wait_for '^b +live ' || die "the two groups are not live: ${out}"
echo "${0##*/}: two server groups, a and b, live through the relay"

entry=$(sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^relay/1 ') || die "relay-entry printed no relay/1 line"
read -r _ _ _ _ site rpbk rsid renc _ <<<"${entry}"
xpath=$(grep -o ' xhttp=[^ ]*' <<<"${entry}" | cut -d= -f2)
kseed=$(grep -o ' kcp=[^ ]*' <<<"${entry}" | cut -d, -f3)
[ "${site}" = "${domain}" ] && [ -n "${xpath}" ] && [ -n "${kseed}" ] && grep -q ' hy2=443' <<<"${entry}" ||
  die "relay-entry's line lacks the site, xhttp=, kcp= or hy2=443"
data=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash-relay_caddy_data)
for _ in $(seq 30); do sudo test -f "${data}/caddy/pki/authorities/local/root.crt" && break; sleep 2; done
mkdir -p "${W}/ca" "${W}/client"
sudo cp "${data}/caddy/pki/authorities/local/root.crt" "${W}/ca/root.crt" || die "Caddy made no CA of its own"

# The devices: an http inbound each, on the rig's loopback, through the
# relay by one transport. The relay sees them from Docker's address, not
# 127.0.0.1, so Xray counts them online.
ins='' outs='' rules=''
way() { # <port> <tag> <outbound settings and stream, as JSON members>
  ins+="${ins:+,}{\"tag\": \"$2\", \"listen\": \"127.0.0.1\", \"port\": $1, \"protocol\": \"http\"}"
  outs+="${outs:+,}{\"tag\": \"$2\", $3}"
  rules+="${rules:+,}{\"inboundTag\": [\"$2\"], \"outboundTag\": \"$2\"}"
}
tls() { printf '"security": "tls", "tlsSettings": {"serverName": "%s", "alpn": ["%s"], "fingerprint": "chrome", "certificates": [{"usage": "verify", "certificateFile": "/ca/root.crt"}]}' "${domain}" "$1"; }
reality() { way "$1" "$2" "\"protocol\": \"vless\", \"settings\": {\"address\": \"127.0.0.1\", \"port\": 443, \"id\": \"$3\", \"encryption\": \"${renc}\", \"flow\": \"xtls-rprx-vision\"}, \"streamSettings\": {\"network\": \"raw\", \"security\": \"reality\", \"realitySettings\": {\"serverName\": \"${domain}\", \"fingerprint\": \"chrome\", \"password\": \"${rpbk}\", \"shortId\": \"${rsid}\"}}"; }
xhttp() { way "$1" "$2" "\"protocol\": \"vless\", \"settings\": {\"address\": \"127.0.0.1\", \"port\": 443, \"id\": \"$3\", \"encryption\": \"${renc}\"}, \"streamSettings\": {\"network\": \"xhttp\", $(tls h2), \"xhttpSettings\": {\"path\": \"/${xpath}\", \"host\": \"${domain}\", \"mode\": \"auto\"}}"; }
kcp() { way "$1" "$2" "\"protocol\": \"vless\", \"settings\": {\"address\": \"127.0.0.1\", \"port\": 8447, \"id\": \"$3\", \"encryption\": \"${renc}\"}, \"streamSettings\": {\"network\": \"kcp\", \"finalmask\": {\"udp\": [{\"type\": \"mkcp-legacy\", \"settings\": {\"value\": \"${kseed}\"}}, {\"type\": \"mkcp-legacy\", \"settings\": {\"header\": \"dtls\"}}]}}"; }
hy2() { way "$1" "$2" "\"protocol\": \"hysteria\", \"settings\": {\"version\": 2, \"address\": \"127.0.0.1\", \"port\": 443}, \"streamSettings\": {\"network\": \"hysteria\", $(tls h3), \"hysteriaSettings\": {\"version\": 2, \"auth\": \"$3\"}, \"finalmask\": {\"quicParams\": {\"keepAlivePeriod\": 10}}}"; }
reality 18201 a-reality "${PHONE_A}"
xhttp 18202 a-xhttp "${PHONE_A}"
kcp 18203 a-kcp "${PHONE_A}"
hy2 18204 a-hy2 "${PHONE_A}"
reality 18211 b-reality "${PHONE_B}"
xhttp 18212 b-xhttp "${PHONE_B}"
kcp 18213 b-kcp "${PHONE_B}"
hy2 18214 b-hy2 "${PHONE_B}"
reality 18221 laptop-b "${LAPTOP_B}"
reality 18222 dup-a "${DUP}"
reality 18223 stranger "${STRANGER}"
printf '{"log": {"loglevel": "warning"}, "inbounds": [%s], "outbounds": [%s], "routing": {"rules": [%s]}}\n' \
  "${ins}" "${outs}" "${rules}" >"${W}/client/config.json"
chmod -R a+rX "${W}/ca" "${W}/client"
sudo docker run -d --name relay-rig-gw-client --network host -v "${W}/client:/etc/xray:ro" -v "${W}/ca:/ca:ro" "${xray}" >/dev/null

# probe <port> [url]: curl's exit code, the HTTP status and the body through
# that device's inbound.
probe() {
  local out rc=0
  out=$(curl --noproxy '' -s -m 8 -x "http://127.0.0.1:$1" -w '\n%{http_code}' "${2:-http://exit.test/}" 2>/dev/null) || rc=$?
  printf '%s %s %s' "${rc}" "${out##*$'\n'}" "${out%$'\n'*}"
}
# gets <label> <port> <body> [tries]: a 200 with that body, 1 s apart.
gets() {
  local p=
  for _ in $(seq "${4:-20}"); do
    p=$(probe "$2")
    [ "${p}" = "0 200 $3" ] && return 0
    sleep 1
  done
  die "$1: got ${p%% *}, not $3"
}
# refused <label> <port>: the request reached the device's inbound (curl
# got past the proxy), and no exit answered.
refused() {
  local p
  p=$(probe "$2")
  case ${p%% *} in 5 | 7) die "$1: the probe never reached the device's inbound" ;; esac
  case ${p} in "0 200 "* | *" exit-"*) die "$1: got through" ;; esac
}
transports="reality xhttp kcp hy2"
port_of() { # <group> <transport>
  local base=18201
  [ "$1" = a ] || base=18211
  case $2 in reality) echo "${base}" ;; xhttp) echo $((base + 1)) ;; kcp) echo $((base + 2)) ;; hy2) echo $((base + 3)) ;; esac
}
site() { curl -sk --max-time 20 -w '\n%{http_code}' --resolve "${domain}:443:127.0.0.1" "https://${domain}$1" || true; }
starts() { sudo docker logs "$(service_container xray)" 2>&1 | grep -c 'core: Xray .* started' || true; }

# Each device, on each transport, to its own group's exit. Hysteria2 waits
# for Caddy's certificate, which Xray restarts until it has.
for g in a b; do
  for t in ${transports}; do gets "phone@${g} by ${t}" "$(port_of "${g}" "${t}")" "exit-${g}" 60; done
done
refused "a device in no list" 18223
echo "${0##*/}: each group's device reaches its own group's exit on REALITY, XHTTP, mKCP and Hysteria2; one in no list gets nothing"

# Subscriptions: each by its prefix, from its own group's server; a prefix
# no list has gets what any other path gets, the site's 404.
cover=$(site "/${TOK_A}0")
[[ ${cover} == *$'\n404' ]] || die "a path that is no subscription did not get the site's 404"
for _ in $(seq 20); do [ "$(site "/${TOK_A}")" = $'subscription of phone@a\n200' ] && break; sleep 3; done
[ "$(site "/${TOK_A}")" = $'subscription of phone@a\n200' ] || die "phone@a's subscription did not come from a's server"
[ "$(site "/${TOK_B}")" = $'subscription of phone@b\n200' ] || die "phone@b's subscription did not come from b's server"
[ "$(site "/0123456789ab${TOK_A:12}")" = "${cover}" ] || die "a prefix no list has did not get the site's 404"
echo "${0##*/}: each group's subscription comes through the relay by its prefix; a prefix no list has gets the site"

# A device added on b's server gets in within 70 s, with no restart.
before=$(starts)
list b "${PHONE_B} phone ${TOK_B:0:12}" "${LAPTOP_B} laptop"
gets "laptop@b, added to b's list" 18221 exit-b 70
[ "$(starts)" = "${before}" ] || die "Xray restarted to let laptop@b in"
echo "${0##*/}: a device added on b's server gets in within 70 s, with no restart"

# An id both groups list, once bytes 6 and 7 are zeroed: dropped from both.
list a "${PHONE_A} phone ${TOK_A:0:12}" "${DUP} dup"
wait_for '^dropped: dup@a, phone@b: one id' 25 || die "the id two groups list is not named dropped: ${out}"
sleep 3
refused "dup@a, dropped" 18222
refused "phone@b, dropped with dup@a" 18211
gets "phone@a, untouched" 18201 exit-a
list a "${PHONE_A} phone ${TOK_A:0:12}"
gets "phone@b, once the copy is gone" 18211 exit-b 70
echo "${0##*/}: an id two groups list is dropped from both, and back once the copy goes"

# Deleted while its download runs: the API can't cut it, so Xray restarts.
before=$(starts)
curl --noproxy '' -sN -m 90 -x http://127.0.0.1:18201 http://exit.test/cgi-bin/slow >"${W}/slow" &
slow=$!
sleep 5
[ "$(wc -c <"${W}/slow")" -gt 0 ] || die "phone@a's download did not start"
list a
for _ in $(seq 75); do [ "$(starts)" -gt "${before}" ] && break; sleep 1; done
[ "$(starts)" -gt "${before}" ] || die "phone@a was deleted while connected, and Xray did not restart"
sleep 5
cut=$(wc -c <"${W}/slow")
sleep 4
[ "$(wc -c <"${W}/slow")" = "${cut}" ] || die "phone@a's download kept flowing after its deletion"
kill "${slow}" 2>/dev/null || true
slow=
for t in ${transports}; do refused "phone@a by ${t}, deleted" "$(port_of a "${t}")"; done
gets "phone@b, unaffected" 18211 exit-b 30
echo "${0##*/}: a device deleted while connected is cut, by a restart of Xray"

# b's server down: b gets nothing, on any transport, and its subscriptions
# the site; a is unaffected.
list a "${PHONE_A} phone ${TOK_A:0:12}"
gets "phone@a, back" 18201 exit-a 70
sudo docker stop relay-rig-gw-srv-b >/dev/null
wait_for '^b +down ' 30 || die "with b's server stopped, b is not down: ${out}"
for t in ${transports}; do refused "phone@b by ${t}, b down" "$(port_of b "${t}")"; done
[ "$(site "/${TOK_B}")" = "${cover}" ] || die "with b down, phone@b's subscription did not get the site"
for t in ${transports}; do gets "phone@a by ${t}, b down" "$(port_of a "${t}")" exit-a; done
echo "${0##*/}: with b's server down, b gets nothing, its subscriptions the site, and a is unaffected"

# The same from a start with b down, before the first round.
sudo morzer restart xray >/dev/null || die "morzer restart xray failed"
gets "phone@a after a restart, b down" 18201 exit-a 60
refused "phone@b after a restart, b down" 18211
refused "phone@b by Hysteria2 after a restart, b down" 18214
wait_for '^b +down ' 30 || die "after a restart with b's server stopped, b is not down: ${out}"
sudo docker start relay-rig-gw-srv-b >/dev/null
gets "phone@b once b is back" 18211 exit-b 90
echo "${0##*/}: after a restart with b down, a gets through and b gets nothing till its server is back"
