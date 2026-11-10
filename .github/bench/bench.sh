#!/usr/bin/env bash
# Measures REALITY, XHTTP, XHTTP with REALITY and mKCP through the installed
# dotdash under added latency and packet loss, and prints JSON. Runs inside a bundle-ci rig after the
# bundle is installed, with .github/smoke.d/pre-apply's upstream and target;
# the benchmark workflow sets that up. Never on a real machine: it changes
# qdiscs, though only on its own clients' interfaces.
#
# Each transport gets a client container on the rig's bridge. netem goes on
# that container's eth0, so it delays and drops what the client sends to the
# server, and nothing else: curl runs in the same network namespace (nsenter)
# and reaches the client's SOCKS inbound over loopback, which netem leaves
# alone. Per scenario and transport: N small fetches (success, time to first
# byte, total time) and M transfers of 1 MiB (completed, throughput). Then,
# unimpaired, how long each client takes to get through again once
# `morzer restart xray` has brought Xray back.
#
#   BENCH_REQUESTS   small fetches per scenario and transport (default 20)
#   BENCH_TRANSFERS  1 MiB transfers per scenario and transport (default 3)
#   BENCH_DELAYS     added delays, <ms>[:<jitter ms>] (default "0 100:30 250:50")
#   BENCH_LOSSES     added loss in percent (default "0 2 5")
set -euo pipefail

requests=${BENCH_REQUESTS:-20}
transfers=${BENCH_TRANSFERS:-3}
delays=${BENCH_DELAYS:-0 100:30 250:50}
losses=${BENCH_LOSSES:-0 2 5}
target=http://11.99.0.10:8000
log() { echo "bench: $*" >&2; }
die() { log "$*"; exit 1; }

command -v tc >/dev/null || apk add --no-cache --quiet iproute2-tc >&2
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
xray=$(docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
[ -n "${host}" ] && [ -n "${xray}" ] || die "no docker0 address or no Xray image in the rig"
work=$(mktemp -d)

# XHTTP with REALITY and mKCP are opt-in: the rig installs the xdns profile, so
# this adds theirs. A release without them measures the first two.
transports="reality xhttp"
if grep -qF 'combinable:' /opt/dotdash/current/manifest.yaml; then
  profile=xdns,xhttp-reality
  transports="${transports} xhttp-reality"
  if grep -qF 'mkcp: [compose/mkcp.yaml]' /opt/dotdash/current/manifest.yaml; then
    profile="${profile},mkcp"
    transports="${transports} mkcp"
  fi
  morzer config set "installation.profile=${profile}" >/dev/null || die "could not switch to ${profile}"
elif grep -qF 'xdns-xhttp-reality:' /opt/dotdash/current/manifest.yaml; then
  morzer config set installation.profile=xdns-xhttp-reality >/dev/null || die "could not switch to xdns-xhttp-reality"
  transports="${transports} xhttp-reality"
fi

# Clients from client-config's links, pointed at this rig's server.
links=$(morzer task run client-config --output)
reality=$(grep -m1 '^vless://.*security=reality.*type=tcp' <<<"${links}") || die "client-config printed no REALITY link"
xhttp=$(grep -m1 '^vless://.*security=tls.*type=xhttp' <<<"${links}") || die "client-config printed no XHTTP link"
xr=$(grep -m1 '^vless://.*security=reality.*type=xhttp' <<<"${links}") || true
kcp=$(grep -m1 '^vless://.*type=kcp' <<<"${links}") || true
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
caddy=$(docker ps -q --filter label=com.docker.compose.project=dotdash --filter label=com.docker.compose.service=caddy | sed -n 1p)
docker exec "${caddy}" cat /data/caddy/pki/authorities/local/root.crt >"${work}/root.pem"
mkdir -p "${work}/reality" "${work}/xhttp" "${work}/xhttp-reality" "${work}/mkcp"
jq -n --arg host "${host}" --arg id "$(id "${reality}")" --arg enc "$(param "${reality}" encryption)" \
  --arg sni "$(param "${reality}" sni)" --arg pbk "$(param "${reality}" pbk)" --arg sid "$(param "${reality}" sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: $host, port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >"${work}/reality/client.json"
path=$(param "${xhttp}" path)
jq -n --arg host "${host}" --arg id "$(id "${xhttp}")" --arg enc "$(param "${xhttp}" encryption)" \
  --arg sni "$(param "${xhttp}" sni)" --arg path "/${path#%2F}" '
  {inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: $host, port: 443, id: $id, encryption: $enc},
     streamSettings: {network: "xhttp", security: "tls",
       tlsSettings: {serverName: $sni, alpn: ["h2"], fingerprint: "chrome",
         certificates: [{usage: "verify", certificateFile: "/ca/root.pem"}]},
       xhttpSettings: {path: $path, host: $sni, mode: "auto"}}}]}' \
  >"${work}/xhttp/client.json"
if [ -n "${xr}" ]; then
  port=${xr#*@} port=${port%%\?*}
  path=$(param "${xr}" path)
  jq -n --arg host "${host}" --argjson port "${port##*:}" --arg id "$(id "${xr}")" \
    --arg enc "$(param "${xr}" encryption)" --arg sni "$(param "${xr}" sni)" --arg pbk "$(param "${xr}" pbk)" \
    --arg sid "$(param "${xr}" sid)" --arg path "/${path#%2F}" '
    {inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: $host, port: $port, id: $id, encryption: $enc},
       streamSettings: {network: "xhttp", security: "reality",
         realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid},
         xhttpSettings: {path: $path, mode: "auto"}}}]}' \
    >"${work}/xhttp-reality/client.json"
fi
if [ -n "${kcp}" ]; then
  port=${kcp#*@} port=${port%%\?*}
  jq -n --arg host "${host}" --argjson port "${port##*:}" --arg id "$(id "${kcp}")" \
    --arg enc "$(param "${kcp}" encryption)" --arg seed "$(param "${kcp}" seed)" --arg header "$(param "${kcp}" headerType)" '
    {inbounds: [{listen: "127.0.0.1", port: 1080, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: $host, port: $port, id: $id, encryption: $enc},
       streamSettings: {network: "kcp", finalmask: {udp:
         ([{type: "mkcp-legacy", settings: {value: $seed}}]
          + (if $header == "none" then [] else [{type: "mkcp-legacy", settings: {header: $header}}] end))}}}]}' \
    >"${work}/mkcp/client.json"
fi
chmod -R a+rX "${work}"

declare -A pid
for t in ${transports}; do
  docker rm -f "bench-${t}" >/dev/null 2>&1 || true
  docker run -d --name "bench-${t}" -v "${work}/${t}:/etc/xray:ro" -v "${work}/root.pem:/ca/root.pem:ro" \
    "${xray}" >/dev/null
  pid[${t}]=$(docker inspect -f '{{.State.Pid}}' "bench-${t}")
done

in_client() { local t=$1; shift; nsenter -t "${pid[${t}]}" -n "$@"; }
fetch() { # <transport> <url> <max seconds>: "<code> <ttfb s> <total s> <bytes>"
  in_client "$1" curl -s -o /dev/null --max-time "$3" --socks5-hostname 127.0.0.1:1080 \
    -w '%{http_code} %{time_starttransfer} %{time_total} %{size_download}\n' "$2" || true
}
impair() { # <transport> <delay ms> <jitter ms> <loss %>
  local args=()
  in_client "$1" tc qdisc del dev eth0 root 2>/dev/null || true
  [ "$2" = 0 ] || args+=(delay "$2ms" "$3ms")
  [ "$4" = 0 ] || args+=(loss "$4%")
  [ ${#args[@]} -eq 0 ] || in_client "$1" tc qdisc add dev eth0 root netem "${args[@]}"
}
for t in ${transports}; do
  for _ in $(seq 30); do
    [ "$(fetch "${t}" "${target}/" 5 | cut -d' ' -f1)" = 200 ] && continue 2
    sleep 1
  done
  die "the ${t} client never got through, unimpaired"
done

# stdin: fetch lines. Prints a JSON object; <bytes>, if given, is the size a
# fetch must have to count.
stats() { # <count> [bytes]
  awk -v n="$1" -v want="${2:-}" '
    function pct(a, k, p,   i) { i = int((k * p + 99) / 100); if (i < 1) i = 1; return a[i] }
    function sort(a, k,   i, j, x) { for (i = 2; i <= k; i++) { x = a[i]; for (j = i - 1; j > 0 && a[j] > x; j--) a[j + 1] = a[j]; a[j + 1] = x } }
    $1 == 200 && (want == "" || $4 == want) { k++; ttfb[k] = $2 * 1000; total[k] = $3 * 1000; mbps[k] = $3 > 0 ? $4 * 8 / $3 / 1e6 : 0 }
    END {
      sort(ttfb, k); sort(total, k); sort(mbps, k)
      printf "{\"of\": %d, \"ok\": %d, \"success_rate\": %.3f", n, k, n ? k / n : 0
      if (k) {
        printf ", \"ttfb_ms\": {\"p50\": %.0f, \"p95\": %.0f}, \"total_ms\": {\"p50\": %.0f, \"p95\": %.0f}", pct(ttfb, k, 50), pct(ttfb, k, 95), pct(total, k, 50), pct(total, k, 95)
        if (want != "") printf ", \"mbps_p50\": %.2f", pct(mbps, k, 50)
      }
      printf "}\n"
    }'
}

: >"${work}/scenarios.jsonl"
for d in ${delays}; do
  delay=${d%%:*} jitter=0
  [ "${d}" = "${delay}" ] || jitter=${d#*:}
  for loss in ${losses}; do
    log "delay ${delay}ms±${jitter}ms, loss ${loss}%"
    for t in ${transports}; do
      impair "${t}" "${delay}" "${jitter}" "${loss}"
      small=$(for _ in $(seq "${requests}"); do fetch "${t}" "${target}/" 15; done | stats "${requests}")
      big=$(for _ in $(seq "${transfers}"); do fetch "${t}" "${target}/blob" 90; done | stats "${transfers}" 1048576)
      jq -cn --arg t "${t}" --argjson d "${delay}" --argjson j "${jitter}" --argjson l "${loss}" \
        --argjson small "${small}" --argjson big "${big}" \
        '{delay_ms: $d, jitter_ms: $j, loss_pct: $l, transport: $t, requests: $small, transfers: $big}' \
        >>"${work}/scenarios.jsonl"
    done
  done
done
for t in ${transports}; do impair "${t}" 0 0 0; done

# Unimpaired: once `morzer restart xray` returns, Xray is healthy again; how
# long until each client gets through.
declare -A reconnect
for t in ${transports}; do
  morzer restart xray >/dev/null
  start=${EPOCHREALTIME}
  until [ "$(fetch "${t}" "${target}/" 5 | cut -d' ' -f1)" = 200 ]; do
    awk -v s="${start}" -v n="${EPOCHREALTIME}" 'BEGIN { exit !(n - s > 60) }' && break
    sleep 0.2
  done
  reconnect[${t}]=$(awk -v s="${start}" -v n="${EPOCHREALTIME}" 'BEGIN { printf "%.2f", n - s }')
done

for t in ${transports}; do docker rm -f "bench-${t}" >/dev/null; done
reconnected=$(for t in ${transports}; do echo "${t} ${reconnect[${t}]}"; done |
  jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add')
jq -s --arg xray "$(docker run --rm --entrypoint /usr/local/bin/xray "${xray}" version | sed -n 1p)" \
  --arg release "$(morzer status --json 2>/dev/null | jq -r '.data.current_release.version // empty' 2>/dev/null)" \
  --arg kernel "$(uname -r)" --argjson requests "${requests}" --argjson transfers "${transfers}" \
  --argjson reconnect "${reconnected}" '
  {xray: $xray, release: $release, kernel: $kernel, requests: $requests, transfers: $transfers,
   netem: "on the client container'"'"'s egress (client to server)",
   reconnect_after_restart_s: $reconnect,
   scenarios: .}' "${work}/scenarios.jsonl"
