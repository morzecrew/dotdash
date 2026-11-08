#!/usr/bin/env bash
# What the README promises about revoking a device:
#
# 1. a device added to vless_clients gets through with its own links;
# 2. deleting its line locks it out, and the other devices keep working;
# 3. rotating reality_key locks out every link printed before, and the links
#    client-config prints after work.
#
# Each device is a REALITY client built from client-config's link for it, as
# 10-clients.sh builds them; 10-clients.sh's own client (SOCKS on 11080) is the
# device that stays.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

target=http://11.99.0.10:8000/
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }

device() { # <name> <socks port> [all]: a REALITY client from that client's link, or the first of all
  local link dir=/rig/clients/$1 only=(-- "$1")
  [ "${3:-}" != all ] || only=()
  link=$(sudo morzer task run client-config --output "${only[@]}" | grep -m1 '^vless://.*security=reality') \
    || die "client-config printed no REALITY link for ${3:-$1}"
  mkdir -p "${dir}"
  jq -n --argjson port "$2" --arg id "$(id "${link}")" --arg enc "$(param "${link}" encryption)" \
    --arg sni "$(param "${link}" sni)" --arg pbk "$(param "${link}" pbk)" --arg sid "$(param "${link}" sid)" '
    {inbounds: [{listen: "127.0.0.1", port: $port, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
       streamSettings: {network: "raw", security: "reality",
         realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
    >"${dir}/client.json"
  chmod -R a+rX "${dir}"
  sudo docker rm -f "dotdash-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-$1" --network host -v "${dir}:/etc/xray:ro" "${xray}" >/dev/null
}
gets_through() { # <socks port>
  curl -fsS -o /dev/null --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}
locked_out() { # <socks port>: no answer, even after Xray has had time to restart
  sleep 3
  ! curl -fsS -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}

secrets=/run/dotdash/secrets
before=$(sudo cat "${secrets}/vless_clients")
spare=$(cat /proc/sys/kernel/random/uuid)
printf '%s\n%s spare\n' "${before}" "${spare}" | sudo morzer secret set vless_clients >/dev/null
device spare 11090
gets_through 11090 || die "a device added to vless_clients does not get through"
echo "45-revocation.sh: a device added to vless_clients gets through"

printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null
locked_out 11090 || die "a device whose line was deleted still gets through"
gets_through 11080 || die "deleting one device's line locked out another"
echo "45-revocation.sh: deleting a device's line locks it out, and the others keep working"

sudo morzer secret rotate reality_key >/dev/null
locked_out 11080 || die "a link printed before reality_key was rotated still gets through"
# The device that stayed is the only one left; its line may have no name.
device rotated 11091 all
gets_through 11091 || die "a link printed after reality_key was rotated does not get through"
echo "45-revocation.sh: rotating reality_key locks out the old links, and the new ones work"
