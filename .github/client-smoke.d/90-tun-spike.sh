#!/usr/bin/env bash
# SPIKE, not for merging: can ghcr.io/morzecrew/mihomo run TUN mode, and how?
# It runs a second mihomo by hand on the rig's own network (the rig is a
# privileged container with a network namespace of its own; nothing here
# reaches the machine running it), from the same subscription as the bundle,
# and reports what it sees. It never fails the job; read its output.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -uo pipefail

mihomo=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/mihomo | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
dir=/rig/tun
sudo rm -rf "${dir}" && sudo mkdir -p "${dir}/etc" "${dir}/secrets"
printf 'http://%s:8088/sub' "${host}" | sudo tee "${dir}/secrets/subscription_url" >/dev/null
# As morzer renders secrets: 0400, owned by 65532.
sudo chown 65532:65532 "${dir}/secrets/subscription_url" && sudo chmod 0400 "${dir}/secrets/subscription_url"
jq -n '{
  mode: "rule", "log-level": "info", ipv6: false,
  tun: {enable: true, stack: "system", "auto-route": true, "auto-detect-interface": true,
        "dns-hijack": ["any:53"], "exclude-interface": ["docker0"]},
  dns: {enable: true, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
        nameserver: ["https://1.1.1.1/dns-query"], "proxy-server-nameserver": ["1.1.1.1"]},
  "proxy-providers": {dotdash: {type: "http", url: {"$file": "/run/secrets/subscription_url"},
    interval: 3600, path: "./proxies/dotdash.yaml", proxy: "dotdash"}},
  "proxy-groups": [{name: "dotdash", type: "url-test", use: ["dotdash"],
    url: "https://www.gstatic.com/generate_204", interval: 300}],
  rules: ["MATCH,dotdash"]}' | sudo tee "${dir}/etc/config.json" >/dev/null
sudo chmod -R a+rX "${dir}/etc"

standin() { sudo docker logs client-rig-server 2>&1 | grep -c ' accepted tcp:' || true; }
attempt() { # <name> <docker run options...>: start the TUN mihomo, report, stop it
  local name=$1; shift
  echo "=== spike ${name}: $*"
  sudo docker rm -f tun-spike >/dev/null 2>&1
  sudo docker volume rm -f tun-spike-home >/dev/null 2>&1
  sudo docker run -d --name tun-spike --network host --read-only --security-opt no-new-privileges:true \
    --cap-drop ALL --device /dev/net/tun -v tun-spike-home:/var/lib/mihomo \
    -v "${dir}/etc:/etc/mihomo:ro" -v "${dir}/secrets/subscription_url:/run/secrets/subscription_url:ro" \
    "$@" "${mihomo}" >/dev/null || { echo "  run refused"; return; }
  sleep 8
  echo "  state: $(sudo docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' tun-spike)"
  sudo docker logs tun-spike 2>&1 | grep -v '\[envconf\]' | tail -12 | sed 's/^/  log: /'
  echo "  links: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
  echo "  rules: $(ip rule show | tr '\n' ';' | cut -c1-400)"
  local before after code
  before=$(standin)
  code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 15 https://www.gstatic.com/generate_204)
  after=$(standin)
  echo "  plain curl from the rig: ${code}; stand-in accepted ${before} -> ${after}"
  sudo docker logs client-rig-server 2>&1 | grep ' accepted tcp:' | tail -2 | sed 's/^/  stand-in: /'
  echo "  resolver: $(nslookup www.example.com 2>&1 | tail -3 | tr '\n' ' ')"
  sudo docker rm -f tun-spike >/dev/null 2>&1
  sleep 2
  echo "  rules after stop: $(ip rule show | tr '\n' ';' | cut -c1-300)"
  code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 15 https://www.gstatic.com/generate_204)
  echo "  plain curl after stop: ${code}"
}

# Round 1 (root with NET_ADMIN alone, then with DAC_READ_SEARCH, then 65532):
# the secrets and the home volume are 65532's, so root needs DAC_OVERRIDE; and
# 65532 gets no capability at all ("configure tun interface: operation not
# permitted").
attempt root-system --user 0:0 --cap-add NET_ADMIN --cap-add DAC_OVERRIDE
sed -i 's/"stack": "system"/"stack": "mixed"/' "${dir}/etc/config.json" 2>/dev/null \
  || sudo sed -i 's/"stack": "system"/"stack": "mixed"/' "${dir}/etc/config.json"
attempt root-mixed --user 0:0 --cap-add NET_ADMIN --cap-add DAC_OVERRIDE
echo "90-tun-spike.sh: done (a spike: read the output above)"
exit 0
