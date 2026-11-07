#!/usr/bin/env bash
# Clients built from client-config's output reach the healthcheck's target
# (pre-apply/10-rig.sh) through both TCP entry points: REALITY on 443, and
# XHTTP through REALITY's fallback to Caddy's secret path.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer task run client-config --output)
reality=$(grep -m1 '^vless://.*security=reality' <<<"${out}") || die "client-config printed no REALITY link"
xhttp=$(grep -m1 '^vless://.*type=xhttp' <<<"${out}") || die "client-config printed no XHTTP link"
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
dir=/rig/clients
mkdir -p "${dir}/reality" "${dir}/xhttp"
sudo docker exec "$(service_container caddy)" cat /data/caddy/pki/authorities/local/root.crt | tee "${dir}/root.pem" >/dev/null

jq -n --arg id "$(id "${reality}")" --arg enc "$(param "${reality}" encryption)" \
  --arg sni "$(param "${reality}" sni)" --arg pbk "$(param "${reality}" pbk)" --arg sid "$(param "${reality}" sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11080, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >"${dir}/reality/client.json"
path=$(param "${xhttp}" path)
jq -n --arg id "$(id "${xhttp}")" --arg enc "$(param "${xhttp}" encryption)" \
  --arg sni "$(param "${xhttp}" sni)" --arg path "/${path#%2F}" '
  {inbounds: [{listen: "127.0.0.1", port: 11081, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc},
     streamSettings: {network: "xhttp", security: "tls",
       tlsSettings: {serverName: $sni, alpn: ["h2"], fingerprint: "chrome",
         certificates: [{usage: "verify", certificateFile: "/ca/root.pem"}]},
       xhttpSettings: {path: $path, host: $sni, mode: "auto"}}}]}' \
  >"${dir}/xhttp/client.json"
chmod -R a+rX "${dir}"

for entry in reality:11080 xhttp:11081; do
  name=${entry%:*} port=${entry#*:}
  sudo docker rm -f "dotdash-rig-${name}" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-${name}" --network host \
    -v "${dir}/${name}:/etc/xray:ro" -v "${dir}/root.pem:/ca/root.pem:ro" "${xray}" >/dev/null
  got=$(curl -fsS --max-time 20 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:${port}" http://target:8000/) \
    || { sudo docker logs "dotdash-rig-${name}" 2>&1 | tail -5 >&2; die "${name}: no answer through the tunnel"; }
  [ "${got}" = ok ] || die "${name}: unexpected answer through the tunnel"
  echo "10-clients.sh: ${name} ok"
done
