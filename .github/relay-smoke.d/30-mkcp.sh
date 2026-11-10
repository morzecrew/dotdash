#!/usr/bin/env bash
# The mkcp profile: the relay serves VLESS over mKCP on kcp_port (8447/udp)
# and carries it on to dotdash like REALITY.
#
# - relay-entry ends the line with kcp=8447,srtp,<the relay's seed>;
# - a listed device with that port, header and seed gets out through the
#   relay and the stand-in server; one with a wrong seed does not;
# - dropping the profile shuts the port, and relay-entry's line loses the field.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'mkcp: [compose/mkcp.yaml]' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates the mkcp profile"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
restore() {
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-kcp relay-rig-kcp-wrong >/dev/null 2>&1 || true
}
trap restore EXIT

# Captured, then read: a reader that stops early would kill the task's output.
entry() { local out; out=$(sudo morzer task run relay-entry --output -- 127.0.0.1); grep -m1 '^127\.0\.0\.1 ' <<<"${out}" || true; }
device() { # <name> <port> <kcp port> <seed> <header>: an mKCP client of the relay, HTTP proxy on 127.0.0.1:<port>
  local enc
  read -r _ _ _ _ enc _ <<<"$(entry)"
  mkdir -p "/rig/relay/$1"
  jq -n --arg id "$(cat /rig/relay/device)" --arg enc "${enc}" --argjson port "$2" --argjson kcp "$3" \
    --arg seed "$4" --arg header "$5" '
    {inbounds: [{listen: "127.0.0.1", port: $port, protocol: "http"}],
     outbounds: [{protocol: "vless",
       settings: {address: "127.0.0.1", port: $kcp, id: $id, encryption: $enc},
       streamSettings: {network: "kcp", finalmask: {udp: [
         {type: "mkcp-legacy", settings: {value: $seed}}, {type: "mkcp-legacy", settings: {header: $header}}]}}}]}' \
    >"/rig/relay/$1/config.json"
  chmod -R a+rX "/rig/relay/$1"
  sudo docker rm -f "relay-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "relay-rig-$1" --network host -v "/rig/relay/$1:/etc/xray:ro" "${xray}" >/dev/null
}
status() { # <port> [retries]: probe_url's status through that device, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry "${2:-5}" --retry-delay 2 --retry-all-errors \
    --proxy "http://127.0.0.1:$1" https://www.gstatic.com/generate_204 || true
}

[[ $(entry) != *kcp=* ]] || die "relay-entry prints a kcp= field without the mkcp profile"
sudo morzer config set installation.profile=mkcp >/dev/null || die "could not switch to the mkcp profile"
field=$(grep -o 'kcp=[^ ]*' <<<"$(entry)") || die "relay-entry printed no kcp= field under mkcp"
[[ ${field} =~ ^kcp=8447,srtp,[0-9a-f]{32}$ ]] || die "relay-entry's kcp= field is not 8447, srtp and a 32-hex seed"
seed=${field##*,}

device kcp 18091 8447 "${seed}" srtp
code=$(status 18091)
[ "${code}" = 204 ] || die "a listed device got ${code} over mKCP through the relay, not 204"
device kcp-wrong 18092 8447 "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')" srtp
code=$(status 18092 0)
[ "${code}" != 204 ] || die "a device with a wrong seed got through the relay's mKCP"
echo "30-mkcp.sh: under mkcp a device gets out over mKCP through the relay; a wrong seed does not"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the mkcp profile"
[[ $(entry) != *kcp=* ]] || die "relay-entry still prints a kcp= field after dropping the profile"
code=$(status 18091 0)
[ "${code}" != 204 ] || die "mKCP still gets through the relay after dropping the profile"
echo "30-mkcp.sh: dropping the profile shuts mKCP and its field"
