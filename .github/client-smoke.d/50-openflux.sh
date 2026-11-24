#!/usr/bin/env bash
# The openflux profile: when every dotdash link fails its probe, the balancer
# hands traffic to the OpenFlux client, which reaches an OpenFlux exit over
# the link in openflux_link. Here the exit runs on the rig over the direct
# transport, which needs no third-party service, and dials out itself.
#
# - the profile on with an empty openflux_link: the client idles, and the
#   links carry traffic as before;
# - the link set: the client reads it;
# - the stand-in server down: traffic still gets out, through OpenFlux; with
#   the exit stopped too, nothing does, so it was OpenFlux;
# - the server, then the profile, go back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^      openflux: \[compose/openflux.yaml\]$' /opt/dotdash-client/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release has no openflux profile"
  exit 0
fi
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
fetch() { # <URL>: its status through the proxy port, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://127.0.0.1:7890 "$1" || true
}
gets() { # <code>: whether a fetch answers with it within 60 s
  local _
  for _ in $(seq 20); do [ "$(fetch https://www.gstatic.com/generate_204)" = "$1" ] && return 0; sleep 3; done
  return 1
}
restore() {
  sudo docker rm -f client-rig-ofexit >/dev/null 2>&1 || true
  sudo docker start client-rig-server >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
}
trap restore EXIT
logs() { sudo docker logs "$(service_container openflux)" 2>&1; }

sudo morzer config set installation.profile=openflux >/dev/null || die "could not turn on the openflux profile"
grep -qF 'openflux_link holds no openflux:// link: idle' <<<"$(logs)" || die "the client does not say it is idle: $(logs | tail -5)"
gets 204 || die "the links stopped carrying traffic once the profile was on"
echo "${0##*/}: the profile on with no link: the client idles, and the links carry traffic"

# An exit of the rig's own, and the link to it, as a server's openflux-link
# task would print it.
image=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/openflux | sed -n 1p)
mkdir -p /rig/client/openflux
key=$(random)
printf '%s' "${key}" >/rig/client/openflux/key
printf '[Interface]\nRole = exit\nMode = l4\nEncryptionKeyFile = /k/key\n\n[Transport d]\nType = direct\nPriority = 50\nListen = 0.0.0.0:8445\n' \
  >/rig/client/openflux/exit.conf
chmod -R a+rX /rig/client/openflux
sudo docker run -d --name client-rig-ofexit -p 8445:8445 --tmpfs /tmp -v /rig/client/openflux:/k:ro "${image}" \
  --config /k/exit.conf >/dev/null
link=$(printf '{"name":"rig","negotiate":true,"secret":"%s","transports":[{"type":"direct","dial":"%s:8445"}]}' "${key}" "${host}" |
  sudo docker run --rm -i "${image}" --make-link - | jq -r .link)
printf 'rig %s\n' "${link}" | sudo morzer secret set openflux_link >/dev/null || die "could not set openflux_link"
for _ in $(seq 20); do grep -qF 'openflux: transport 1: direct' <<<"$(logs)" && break; sleep 3; done
grep -qF 'openflux: transport 1: direct' <<<"$(logs)" || die "the client does not read the link: $(logs | tail -5)"
! grep -qF "${key}" <<<"$(logs)" || die "the client's log holds the link's key"
echo "${0##*/}: the client reads the link, and never logs its key"

# Restarted with the server down, Xray counts the link down from its first
# probe, as in 12-fail-closed.sh.
sudo docker stop client-rig-server >/dev/null
sudo docker restart "$(service_container xray)" >/dev/null
gets 204 || die "with every link down, traffic does not get out through OpenFlux"
sudo docker stop client-rig-ofexit >/dev/null
for _ in 1 2 3; do
  [ "$(fetch https://www.gstatic.com/generate_204)" != 204 ] || die "with the exit stopped too, traffic still gets out: it did not go through OpenFlux"
  sleep 2
done
sudo docker start client-rig-ofexit >/dev/null
gets 204 || die "traffic does not get out again once the exit is back"
echo "${0##*/}: every link down, traffic gets out through OpenFlux, and with its exit stopped nothing does"
