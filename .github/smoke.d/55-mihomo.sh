#!/usr/bin/env bash
# mihomo (ghcr.io/morzecrew/mihomo) gets through with the links client-config
# prints, read as a subscription: REALITY, XHTTP, and XHTTP with REALITY when
# the profile has it, each alone, then all of them behind url-test, as a
# mihomo client runs them. It guards support-x25519mlkem768 in the REALITY
# links, without which mihomo leaves out the key share Xray's REALITY
# requires. The links reach mihomo as a file provider under /run/secrets, the
# one place the image lets providers read besides its home (SAFE_PATHS).
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

mihomo=ghcr.io/morzecrew/mihomo:1.19.33@sha256:84f6ca181df09df3605e1a4b45c94fd2920afbf7e2332d1ae367ae1e12b90b84
target=http://11.99.0.10:8000/
dir=/rig/mihomo
mkdir -p "${dir}"
sudo docker pull -q "${mihomo}" >/dev/null || die "pulling ${mihomo} failed"
domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
links=$(sudo morzer task run client-config --output -- --full | grep '^vless://')
[ -n "${links}" ] || die "client-config printed no links"
base64 -w0 <<<"${links}" >"${dir}/sub"
chmod a+r "${dir}/sub"

run() { # <name> <port> <group>: mihomo whose one group is <group> over the links
  local name=$1 port=$2 got
  mkdir -p "${dir}/${name}"
  jq -n --argjson port "${port}" --arg domain "${domain}" --arg target "${target}" --argjson group "$3" '
    {"mixed-port": $port, "bind-address": "127.0.0.1", "allow-lan": false, mode: "rule",
     "log-level": "warning", ipv6: false, hosts: {($domain): "127.0.0.1"},
     "proxy-providers": {sub: {type: "file", path: "/run/secrets/sub",
       "health-check": {enable: true, url: $target, interval: 30}}},
     "proxy-groups": [$group + {name: "pick", use: ["sub"]}],
     rules: ["MATCH,pick"]}' >"${dir}/${name}/config.json"
  chmod -R a+rX "${dir}/${name}"
  sudo docker rm -f "mihomo-${name}" >/dev/null 2>&1 || true
  # The rig's site certificate is from Caddy's own CA (10-clients.sh).
  sudo docker run -d --name "mihomo-${name}" --network host -e SSL_CERT_FILE=/ca/root.pem \
    -v "${dir}/${name}:/etc/mihomo:ro" -v "${dir}/sub:/run/secrets/sub:ro" \
    -v /rig/clients/root.pem:/ca/root.pem:ro "${mihomo}" >/dev/null
  got=$(curl -fsS --max-time 20 --retry 4 --retry-delay 2 --retry-all-errors \
    --proxy "socks5h://127.0.0.1:${port}" "${target}" 2>&1 || true)
  if [ "$(tail -1 <<<"${got}")" != ok ]; then
    sudo docker logs --tail 5 "mihomo-${name}" 2>&1 | grep -iv 'vless://\|uuid' >&2 || true
    die "mihomo did not get through over ${name}: $(tail -1 <<<"${got}")"
  fi
  sudo docker rm -f "mihomo-${name}" >/dev/null
}

run reality 12081 '{"type": "select", "filter": "\\[reality\\]"}'
run xhttp 12082 '{"type": "select", "filter": "\\[xhttp\\]"}'
if grep -qF '%5Bxhttp%2Breality%5D' <<<"${links}"; then
  run xhttp-reality 12083 '{"type": "select", "filter": "\\[xhttp\\+reality\\]"}'
fi
run url-test 12084 "{\"type\": \"url-test\", \"url\": \"${target}\", \"interval\": 30}"
echo "55-mihomo.sh: mihomo gets through over each transport and behind url-test"
