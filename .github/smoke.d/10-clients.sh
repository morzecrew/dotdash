#!/usr/bin/env bash
# Clients built from client-config's output reach the healthcheck's target
# (pre-apply/10-rig.sh) through every entry point: REALITY on 443, XHTTP
# through REALITY's fallback to Caddy's secret path, and the DNS tunnel (the
# rig installs the xdns profile), queried at the server itself. Then the config
# for v2rayN, with a server that does not exist listed first, with this one
# alone, and with only the server that does not exist, so that it falls back
# to the DNS tunnel.
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
# client-config's Xray config: the lines from the "{" after its heading to the
# matching "}" at the start of a line.
full_config() { awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"$1"; }
# The DNS tunnel's outbound, its resolver pointed at the server: the rig has no
# delegation for the zone. A release before the full config printed it alone.
if grep -q '^XDNS tunnel' <<<"${out}"; then
  xdns=$(awk '/^XDNS tunnel/{on=1; next} on{print} on && /^}$/{exit}' <<<"${out}")
else
  xdns=$(full_config "${out}" | jq '.outbounds[] | select(.tag == "xdns")')
fi
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

# The full config, pointed at the rig: this server at 127.0.0.1 trusting
# Caddy's CA, the DNS tunnel's resolver at the server, and an observatory that
# probes the rig's target every 5s. A server that does not exist stays as is.
rig_config() { # <socks port>
  jq --argjson port "$1" '.inbounds = [{listen: "127.0.0.1", port: $port, protocol: "socks"}]
    | .outbounds |= map(
        (if .settings.address == "dotdash.test" then .settings.address = "127.0.0.1" else . end)
        | (if .streamSettings.security == "tls"
           then .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]
           else . end)
        | (if .tag == "xdns"
           then .streamSettings.finalmask.udp[0].settings.resolvers = [{addrs: ["udp://127.0.0.1:53"]}]
           else . end))
    | .observatory.probeUrl = "http://target:8000/" | .observatory.probeInterval = "5s"'
}
config_check() { # <name> <socks port> <servers>: client-config's config with those servers
  local out config
  sudo morzer config set "servers=$3" >/dev/null || die "config set servers=$3 failed"
  out=$(sudo morzer task run client-config --output)
  sudo morzer config unset servers >/dev/null
  config=$(full_config "${out}")
  [ -n "${config}" ] || die "$1: client-config printed no Xray config for servers=$3"
  mkdir -p "${dir}/$1"
  rig_config "$2" <<<"${config}" >"${dir}/$1/client.json"
  chmod -R a+rX "${dir}/$1"
  check "$1" "$2"
}

# A release from before the servers parameter has nothing to check.
if sudo morzer config list 2>/dev/null | grep -qw servers; then
  # A server that does not answer first, then this one: the config uses the
  # one that answers.
  config_check failover 11083 gone.dotdash.test,self
  # Before the full config, a release printed a config for several servers
  # alone, and none with the DNS tunnel as its last resort.
  if grep -q 'only when none answers' <<<"$(sudo morzer task run client-config --output)"; then
    config_check config 11084 self
    # No server answers, so the config falls back to the DNS tunnel.
    config_check fallback 11085 gone.dotdash.test
  fi
fi
