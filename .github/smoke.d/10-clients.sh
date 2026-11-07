#!/usr/bin/env bash
# Clients built from client-config's output reach the healthcheck's target
# (pre-apply/10-rig.sh) through every entry point: REALITY on 443, XHTTP
# through REALITY's fallback to Caddy's secret path, and the DNS tunnel (the
# rig installs the xdns profile), queried at the server itself. Then the config
# that moves between servers, with a server that does not exist listed first.
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
mkdir -p "${dir}/reality" "${dir}/xhttp" "${dir}/xdns" "${dir}/failover"
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
# The printed outbound, its resolver pointed at the server: the rig has no
# delegation for the zone.
xdns=$(awk '/^XDNS tunnel/{on=1; next} on{print} on && /^}$/{exit}' <<<"${out}")
[ -n "${xdns}" ] || die "client-config printed no XDNS outbound"
jq '{inbounds: [{listen: "127.0.0.1", port: 11082, protocol: "socks"}],
   outbounds: [.streamSettings.finalmask.udp[0].settings.resolvers = [{addrs: ["udp://127.0.0.1:53"]}]]}' \
  <<<"${xdns}" >"${dir}/xdns/client.json"
chmod -R a+rX "${dir}"

check() { # <name> <socks port>
  sudo docker rm -f "dotdash-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-$1" --network host \
    -v "${dir}/$1:/etc/xray:ro" -v "${dir}/root.pem:/ca/root.pem:ro" "${xray}" >/dev/null
  got=$(curl -fsS --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$2" http://target:8000/) \
    || { sudo docker logs "dotdash-rig-$1" 2>&1 | tail -5 >&2; die "$1: no answer through the tunnel"; }
  [ "${got}" = ok ] || die "$1: unexpected answer through the tunnel"
  echo "10-clients.sh: $1 ok"
}
check reality 11080
check xhttp 11081
check xdns 11082

# A release from before the servers parameter has nothing to check.
if sudo morzer config list 2>/dev/null | grep -qw servers; then
  sudo morzer config set servers=gone.dotdash.test,self >/dev/null || die "config set servers failed"
  out=$(sudo morzer task run client-config --output)
  sudo morzer config unset servers >/dev/null
  failover=$(awk '/^Xray client config that moves/{on=1; getline; next} on{print} on && /^}$/{exit}' <<<"${out}")
  [ -n "${failover}" ] || die "client-config printed no failover config for two servers"
  jq '.inbounds = [{listen: "127.0.0.1", port: 11083, protocol: "socks"}]
    | .outbounds |= map(
        (if .settings.address == "dotdash.test" then .settings.address = "127.0.0.1" else . end)
        | (if .streamSettings.security == "tls"
           then .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]
           else . end))
    | .observatory.probeUrl = "http://target:8000/" | .observatory.probeInterval = "5s"' \
    <<<"${failover}" >"${dir}/failover/client.json"
  chmod a+r "${dir}/failover/client.json"
  check failover 11083
fi
