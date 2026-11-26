#!/usr/bin/env bash
# The device-traffic profile, beside CI's xdns: Xray counts each device's
# bytes, and the facts task, run in Xray's namespace, carries them by device
# name with when Xray started. A fetch through a REALITY client of this
# hook's own raises its device's count, and the policy hook still holds
# (doctor). Back on xdns, the facts carry no counts. Xray counts a device by
# its name: the rig's devices have none (vless_clients' generator writes a
# bare UUID), so the client's line gets one here, taken off after.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

secrets=/run/dotdash/secrets
before=$(sudo cat "${secrets}/vless_clients")
restore() {
  printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null 2>&1 || true
  sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-counted >/dev/null 2>&1 || true
}
trap restore EXIT

# A REALITY client of this hook's own, from the links as they are now:
# 45-revocation.sh rotates reality_key, which locks 10-clients.sh's out.
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
link=$(sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality.*type=tcp') ||
  die "client-config printed no REALITY link"
param() { sed -n "s/.*[?&]$1=\([^&#]*\).*/\1/p" <<<"${link}"; }
rest=${link#vless://}
mkdir -p /rig/clients/counted
jq -n --arg id "${rest%%@*}" --arg enc "$(param encryption)" --arg sni "$(param sni)" \
  --arg pbk "$(param pbk)" --arg sid "$(param sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11183, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >/rig/clients/counted/client.json
chmod -R a+rX /rig/clients/counted
fetch() { # through this hook's REALITY client
  curl -sS -o /dev/null --max-time 20 --retry 5 --retry-delay 2 --retry-all-errors \
    -w '%{http_code}' --socks5-hostname 127.0.0.1:11183 http://11.99.0.10:8000/
}
counted() { # the client's device's bytes in the facts' counts
  local facts
  facts=$(sudo morzer task run facts --output) || die "the facts task failed under device-traffic"
  jq -e '.domain and (.traffic.started | type == "number") and (.traffic.devices | type == "object")' \
    >/dev/null <<<"${facts}" || die "the facts carry no counts under device-traffic: ${facts}"
  jq '.traffic.devices.counted // 0' <<<"${facts}"
}

id=${rest%%@*}
named=$(awk -v id="${id}" '$1 == id {print id, "counted"; found=1; next} {print} END {exit !found}' <<<"${before}") ||
  die "the REALITY link's id is not in vless_clients"
printf '%s\n' "${named}" | sudo morzer secret set vless_clients >/dev/null || die "could not name the client's device"
sudo morzer config set installation.profile=xdns,device-traffic >/dev/null || die "could not switch to xdns,device-traffic"
sudo docker rm -f dotdash-rig-counted >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-counted --network host -v /rig/clients/counted:/etc/xray:ro "${xray}" >/dev/null
[ "$(fetch)" = 200 ] || die "the REALITY client got nowhere under device-traffic"
first=$(counted)
[ "${first}" -gt 0 ] || die "a fetch through the device counted left no count"
fetch >/dev/null
second=$(counted)
[ "${second}" -gt "${first}" ] || die "a second fetch did not raise its count (${first}, then ${second})"
out=$(sudo morzer doctor 2>&1) || die "doctor fails under device-traffic: ${out}"
echo "${0##*/}: under device-traffic, the facts count each device's bytes, policy holding"

restore
facts=$(sudo morzer task run facts --output) || die "the facts task failed back on xdns"
jq -e 'has("traffic") | not' >/dev/null <<<"${facts}" || die "back on xdns, the facts still carry counts"
echo "${0##*/}: back on xdns, the facts carry no counts"
