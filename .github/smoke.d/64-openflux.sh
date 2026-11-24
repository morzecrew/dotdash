#!/usr/bin/env bash
# The openflux profile: an OpenFlux exit per device listed in
# openflux_channels, whose connections leave through the gate. Here over the
# direct transport, which needs no third-party service.
#
# - the profile on with no line: openflux idles, and says so;
# - a line for the rig's device and one for a device vless_clients lacks: the
#   first gets a channel, and openflux-link its link; the second is named in
#   the log;
# - a client of this hook's own, from that link, reaches the rig's target,
#   and the rig's upstream logs the fetch: the exit left through the gate;
# - the line removed: openflux-link prints no channel, and the device's key
#   is kept for its return;
# - openflux on inside, beside Xray, is a policy violation;
# - the line, then the xdns profile CI installs, go back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^      openflux: \[compose/openflux.yaml\]$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release has no openflux profile"
  exit 0
fi
log=/rig/upstream-log/access.log
device=$(sudo awk '$1 !~ /^#/ && NF { print $1; exit }' /run/dotdash/secrets/vless_clients)
channels() { printf '%s\n' "$@" | sudo morzer config set --set-file openflux_channels=- >/dev/null; }
restore() {
  sudo docker rm -f dotdash-rig-ofclient >/dev/null 2>&1 || true
  channels '# One device per line: <device> <type>[=<link>] ...' || true
  sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true
}
trap restore EXIT
logs() { sudo docker logs "$(service_container openflux)" 2>&1; }
says() { # <text>: whether openflux's log says it within 60 s
  local _
  for _ in $(seq 20); do grep -qF "$1" <<<"$(logs)" && return 0; sleep 3; done
  return 1
}

sudo morzer config set installation.profile=xdns,openflux >/dev/null || die "could not turn on the openflux profile"
says 'openflux: no channel to run: idle' || die "openflux does not say it is idle: $(logs | tail -5)"
echo "${0##*/}: the profile on with no line: openflux idles"
# The image the profile pulled, for this hook's client.
image=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/openflux | sed -n 1p)

channels "${device} direct=0.0.0.0:8445" "ghost direct=0.0.0.0:8446" || die "could not list the rig's device"
says "openflux: ${device}: on 1 transport(s)" || die "the rig's device gets no channel: $(logs | tail -5)"
grep -qF 'openflux: ghost: no such device in vless_clients, no channel' <<<"$(logs)" ||
  die "a line for a device vless_clients lacks is not named: $(logs | grep '^openflux:' | tail -5)"
link=$(sudo morzer task run openflux-link --output -- "${device}" | sed -n "s/^${device} //p")
case ${link} in openflux://v1/*) ;; *) die "openflux-link printed no link for the rig's device: ${link}" ;; esac
echo "${0##*/}: a listed device gets a channel and a link; a device vless_clients lacks is named in the log"

# The client takes the link's key and dials the exit across egress, as no
# device could: the direct transport is for tests.
mkdir -p /rig/clients/ofclient
sudo docker run --rm "${image}" --parse-link "${link}" | jq -r .config.secret >/rig/clients/ofclient/key
printf '[Interface]\nRole = client\nInbound = socks5\nSocks5 = 0.0.0.0:1080\nEncryptionKeyFile = /k/key\nCookieStore = /tmp/cookies.json\n\n[Transport d]\nType = direct\nPriority = 50\nDial = openflux:8445\n' \
  >/rig/clients/ofclient/client.conf
chmod -R a+rX /rig/clients/ofclient
sudo docker rm -f dotdash-rig-ofclient >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-ofclient --network dotdash_egress -p 127.0.0.1:11098:1080 --tmpfs /tmp \
  -v /rig/clients/ofclient:/k:ro "${image}" --config /k/client.conf >/dev/null
before=$(sudo sh -c "grep -c '11.99.0.10:8000' ${log} 2>/dev/null || true")
body=''
for _ in $(seq 20); do
  body=$(curl -s --max-time 10 --socks5-hostname 127.0.0.1:11098 http://11.99.0.10:8000/ 2>/dev/null || true)
  [ "${body}" = ok ] && break
  sleep 3
done
[ "${body}" = ok ] || die "nothing through the OpenFlux client: $(sudo docker logs dotdash-rig-ofclient 2>&1 | tail -5)"
for _ in $(seq 10); do
  [ "$(sudo sh -c "grep -c '11.99.0.10:8000' ${log} 2>/dev/null || true")" -gt "${before}" ] && break
  sleep 2
done
[ "$(sudo sh -c "grep -c '11.99.0.10:8000' ${log} 2>/dev/null || true")" -gt "${before}" ] ||
  die "the rig's upstream did not carry the fetch: the exit went around the gate"
echo "${0##*/}: a client from the link reaches the target, and the rig's upstream carried it"
sudo docker rm -f dotdash-rig-ofclient >/dev/null

channels '# no device' || die "could not clear openflux_channels"
says 'openflux: no channel to run: idle' || die "openflux keeps a channel with no line"
! sudo morzer task run openflux-link --output >/dev/null 2>&1 || die "openflux-link prints a link with no channel"
sudo docker run --rm --network none -v dotdash_openflux:/s:ro --entrypoint test "${image}" -s "/s/${device}/key" ||
  die "the device's key went with its line, though it is still in vless_clients"
echo "${0##*/}: the line removed, openflux-link prints none, and the device keeps its key for its return"

openflux=$(service_container openflux)
sudo docker network connect dotdash_inside "${openflux}"
out=$({ sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' ')
sudo docker network disconnect dotdash_inside "${openflux}"
grep -qF "openflux is on dotdash_inside, where Xray reaches it past the gate's routing" <<<"${out}" ||
  die "policy misses openflux on inside: ${out}"
echo "${0##*/}: openflux on inside, beside Xray, is a policy violation"
