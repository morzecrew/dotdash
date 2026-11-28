#!/usr/bin/env bash
# server_link=xhttp-reality: the relay reaches each group's servers over
# XHTTP with REALITY, on the port and path a servers line's xr= gives (the
# stand-in's 9444, pre-apply/10-server.sh), connections reused across
# devices. The proof that it takes that way: the group's line names a
# REALITY port nothing listens on, beside the right xr=, and the device still
# gets out; back on reality, that line gets the group nowhere.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
line=$(cat /rig/relay/server-line)
restore() {
  sudo morzer config unset server_link >/dev/null 2>&1 || true
  printf '%s\n' "${line}" | sudo morzer secret set servers >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-phone-xhttp >/dev/null 2>&1 || true
}
trap restore EXIT
mkdir -p /rig/relay/phone-xhttp
jq '.inbounds[0].port = 18083' /rig/relay/phone/config.json >/rig/relay/phone-xhttp/config.json
chmod -R a+rX /rig/relay/phone-xhttp
sudo docker run -d --name relay-rig-phone-xhttp --network host -v /rig/relay/phone-xhttp:/etc/xray:ro "${xray}" >/dev/null
fetch() { # <retries>: the status of probe_url through the device, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --retry "$1" --retry-delay 3 --retry-all-errors \
    --proxy http://127.0.0.1:18083 https://www.gstatic.com/generate_204 || true
}

sudo morzer config set server_link=xhttp-reality >/dev/null || die "could not set server_link=xhttp-reality"
grep -qF '"serverLink": "xhttp-reality"' /etc/dotdash-relay/gateway.json || die "server_link did not reach the gateway's config"
# shellcheck disable=SC2086 # one field per word
set -- ${line}
printf '%s\n' "$1 $2 $3 9449 $5 $6 $7 $8 $9 ${10}" | sudo morzer secret set servers >/dev/null ||
  die "could not set a line whose REALITY port nothing listens on"
code=$(fetch 15)
[ "${code}" = 204 ] || die "over XHTTP with REALITY on xr='s port, the device got ${code}, not 204"
echo "${0##*/}: over XHTTP with REALITY on the line's xr=, the device gets out"

sudo morzer config unset server_link >/dev/null || die "could not unset server_link"
code=$(fetch 2)
[ "${code}" != 204 ] || die "back on reality, the device got out by a REALITY port nothing listens on"
restore
trap - EXIT
echo "${0##*/}: back on reality, that line's REALITY port, which nothing listens on, gets the device nowhere"
