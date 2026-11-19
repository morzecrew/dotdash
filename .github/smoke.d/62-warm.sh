#!/usr/bin/env bash
# Upstreams lines tagged warm=<n> (the warm profile): warm, proxy-warm, keeps
# n connections to the line's proxy open and serves the line on 1080+k, which
# the gate dials for it, so a new connection skips the proxy's handshake.
#
# - the profile on before any line is tagged: warm runs idle, and the proxy
#   still carries traffic;
# - the rig's line tagged warm=2: the gate dials warm for it, warm shows the
#   proxy and never its login, and traffic flows, through warm: with warm
#   stopped, nothing gets out, and doctor names the line and warm; with it
#   back, traffic flows again;
# - warm on inside, beside Xray, is a policy violation;
# - the proxy's line, then the xdns profile CI installs, go back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^      warm: \[compose/warm.yaml\]$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release has no warm profile"
  exit 0
fi
conn=$(cat /rig/upstream.conn)
one="http://${conn} name=rig"
list() { printf '%s\n' "$@" | sudo morzer secret set upstreams >/dev/null; }
# warm's container, stopped or not: service_container finds running ones only.
warm_container() {
  sudo docker ps -aq --filter label=com.docker.compose.project=dotdash --filter label=com.docker.compose.service=warm | sed -n 1p
}
restore() {
  sudo docker rm -f dotdash-rig-warmclient >/dev/null 2>&1 || true
  [ -z "$(warm_container)" ] || sudo docker start "$(warm_container)" >/dev/null 2>&1 || true
  list "${one}" || true
  sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true
}
trap restore EXIT

# A REALITY client of this hook's own, from the links as they are now:
# 45-revocation.sh rotates reality_key, which locks 10-clients.sh's out.
xray_client=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
link=$(sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality.*type=tcp') ||
  die "client-config printed no REALITY link"
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
rest=${link#vless://}
mkdir -p /rig/clients/warmclient
jq -n --arg id "${rest%%@*}" --arg enc "$(param "${link}" encryption)" --arg sni "$(param "${link}" sni)" \
  --arg pbk "$(param "${link}" pbk)" --arg sid "$(param "${link}" sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11099, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >/rig/clients/warmclient/client.json
chmod -R a+rX /rig/clients/warmclient
sudo docker rm -f dotdash-rig-warmclient >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-warmclient --network host -v /rig/clients/warmclient:/etc/xray:ro "${xray_client}" >/dev/null

code() { # through this hook's REALITY client: 301 through the upstream
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --socks5-hostname 127.0.0.1:11099 http://1.1.1.1/ 2>/dev/null || true
}
becomes() { # <code>: whether fetches answer with it within 60 s
  local _
  for _ in $(seq 20); do [ "$(code)" = "$1" ] && return 0; sleep 3; done
  return 1
}
logs() { sudo docker logs "$(service_container "$1")" 2>&1; }

sudo morzer config set installation.profile=xdns,warm >/dev/null || die "could not turn on the warm profile before any line is tagged"
grep -qF 'has no line tagged warm=: nothing to keep ready' <<<"$(logs warm)" ||
  die "warm does not say it is idle: $(logs warm | tail -5)"
becomes 301 || die "the proxy stopped carrying traffic once the warm profile was on (last: $(code))"
echo "${0##*/}: the profile on before any line is tagged: warm idles, and the proxy carries traffic"

list "name=rig warm=2 | http://${conn}" || die "could not tag the rig's line warm=2"
becomes 301 || die "traffic does not flow once the rig's line is tagged warm=2 (last: $(code))"
hostport=${conn##*@}
grep -qF "(rig) socks ${hostport} via warm:1080" <<<"$(logs gate)" ||
  die "the gate does not dial warm for the rig's line: $(logs gate | grep -F upstreams | tail -2)"
grep -qF ":1080 <- line 1 (rig) http ${hostport}, 2 kept ready" <<<"$(logs warm)" ||
  die "warm does not serve the rig's line on 1080: $(logs warm | tail -5)"
! grep -qF "${conn%@*}" <<<"$(logs warm)" || die "warm's log holds the rig's login"
echo "${0##*/}: a line tagged warm=2 is dialled at warm, which holds its login and never logs it, and traffic flows"

warm=$(service_container warm)
sudo docker stop "${warm}" >/dev/null
for _ in $(seq 10); do [ "$(code)" != 301 ] && break; sleep 2; done
[ "$(code)" != 301 ] || die "traffic still flows with warm stopped: the line does not go through it"
out=$({ sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' ')
grep -qF "rig (warm=): warm, the warm profile's container, is not running" <<<"${out}" ||
  die "with warm stopped, doctor does not name the line and warm: ${out}"
sudo docker start "${warm}" >/dev/null
becomes 301 || die "traffic does not flow again once warm is back (last: $(code))"
echo "${0##*/}: the line goes through warm: with it stopped, nothing gets out and doctor says why; with it back, traffic flows"

warm=$(service_container warm)
sudo docker network connect dotdash_inside "${warm}"
out=$({ sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' ')
sudo docker network disconnect dotdash_inside "${warm}"
grep -qF "warm is on dotdash_inside, where Xray reaches it past the gate's routing" <<<"${out}" ||
  die "policy misses warm on inside: ${out}"
sudo morzer doctor >/dev/null 2>&1 || die "doctor still fails with warm off inside again: $(sudo morzer doctor 2>&1 | tail -3)"
echo "${0##*/}: warm on inside, beside Xray, is a policy violation"
