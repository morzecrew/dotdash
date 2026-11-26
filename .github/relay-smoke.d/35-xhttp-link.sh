#!/usr/bin/env bash
# dotdash_link=xhttp-reality: the relay reaches the server over XHTTP with
# REALITY, on the stand-in's 9444 (pre-apply/10-server.sh), connections reused
# across devices, and a listed device still gets out through it; back on
# reality, the link is REALITY with Vision again.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
entry=$(sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^127\.0\.0\.1 ' || true)
read -r host site pbk sid enc <<<"${entry}"
mkdir -p /rig/relay/phone-xhttp
jq -n --arg host "${host}" --arg site "${site}" --arg pbk "${pbk}" --arg sid "${sid}" --arg enc "${enc}" \
  --arg id "$(cat /rig/relay/device)" '
  {inbounds: [{listen: "127.0.0.1", port: 18083, protocol: "http"}],
   outbounds: [{protocol: "vless",
     settings: {address: $host, port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {serverName: $site, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >/rig/relay/phone-xhttp/config.json
chmod -R a+rX /rig/relay/phone-xhttp
sudo docker rm -f relay-rig-phone-xhttp >/dev/null 2>&1 || true
sudo docker run -d --name relay-rig-phone-xhttp --network host -v /rig/relay/phone-xhttp:/etc/xray:ro "${xray}" >/dev/null
fetch() { # the status of probe_url through the device, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --proxy http://127.0.0.1:18083 https://www.gstatic.com/generate_204 || true
}

printf %s "$(cat /rig/relay/xhttp_path)" | sudo morzer secret set dotdash_xhttp_path >/dev/null || die "could not set dotdash_xhttp_path"
sudo morzer config set dotdash_link=xhttp-reality dotdash_xhttp_reality_port=9444 >/dev/null \
  || die "could not set dotdash_link=xhttp-reality"
sudo jq -e '.outbounds[0] | .settings.port == 9444 and .settings.flow == null
  and .streamSettings.network == "xhttp" and .streamSettings.security == "reality"
  and .streamSettings.xhttpSettings.mode == "auto"' /etc/dotdash-relay/xray.json >/dev/null \
  || die "dotdash_link=xhttp-reality did not put the link on XHTTP with REALITY: $(sudo jq -c '.outbounds[0]' /etc/dotdash-relay/xray.json)"
code=$(fetch)
[ "${code}" = 204 ] || die "over the XHTTP link the listed device got ${code}, not 204"
echo "35-xhttp-link.sh: over XHTTP with REALITY to the server, the listed device gets out"

sudo morzer config unset dotdash_link >/dev/null || die "could not unset dotdash_link"
sudo morzer config unset dotdash_xhttp_reality_port >/dev/null || die "could not unset dotdash_xhttp_reality_port"
sudo jq -e '.outbounds[0] | .settings.flow == "xtls-rprx-vision" and .streamSettings.network == "raw"' \
  /etc/dotdash-relay/xray.json >/dev/null || die "back on reality, the link is not REALITY with Vision"
code=$(fetch)
[ "${code}" = 204 ] || die "back on reality the listed device got ${code}, not 204"
sudo docker rm -f relay-rig-phone-xhttp >/dev/null
echo "35-xhttp-link.sh: back on reality, the link is REALITY with Vision and the device gets out"
