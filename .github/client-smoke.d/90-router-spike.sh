#!/usr/bin/env bash
# SPIKE, not for merging: can mihomo's TUN carry other LAN devices' traffic
# when they use this machine as their gateway, on a Docker host, whose FORWARD
# policy is DROP? A "LAN device" is a network namespace behind a veth, with the
# rig as its gateway. A standalone mihomo (as in the TUN spike, #47) runs on
# the rig's network with a host-network stand-in on eth0:9444, which TUN leaves
# out by uid (65532). It never fails the job; read its output.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -uo pipefail

sudo apk add -q iproute2 nftables >/dev/null 2>&1 || echo "apk add failed"
mihomo=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/mihomo | sed -n 1p)
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
eth0=$(ip -4 -o addr show eth0 | awk '{ sub("/.*", "", $4); print $4 }')
dir=/rig/router
sudo rm -rf "${dir}" && sudo mkdir -p "${dir}/etc" "${dir}/secrets" "${dir}/standin"

jq '.inbounds[0].port = 9444' /rig/client/server/config.json | sudo tee "${dir}/standin/config.json" >/dev/null
base64 -d </rig/client/www/sub | sed "s/@${host}:9443/@${eth0}:9444/" | base64 -w0 | sudo tee "${dir}/secrets/sub" >/dev/null
sudo chown 65532:65532 "${dir}/secrets/sub" && sudo chmod 0400 "${dir}/secrets/sub"
sudo chmod -R a+rX "${dir}/standin"
sudo docker rm -f router-standin >/dev/null 2>&1
sudo docker run -d --name router-standin --network host -v "${dir}/standin:/etc/xray:ro" "${xray}" >/dev/null

# The LAN device: 10.99.0.2 behind lanbr (10.99.0.1), resolving with 1.1.1.1.
sudo ip netns add lan
sudo ip link add lanbr type veth peer name lanif
sudo ip link set lanif netns lan
sudo ip addr add 10.99.0.1/24 dev lanbr && sudo ip link set lanbr up
sudo ip netns exec lan ip addr add 10.99.0.2/24 dev lanif
sudo ip netns exec lan ip link set lanif up && sudo ip netns exec lan ip link set lo up
sudo ip netns exec lan ip route add default via 10.99.0.1
sudo mkdir -p /etc/netns/lan && echo 'nameserver 1.1.1.1' | sudo tee /etc/netns/lan/resolv.conf >/dev/null
echo "ip_forward=$(cat /proc/sys/net/ipv4/ip_forward) FORWARD policy: $(sudo iptables -S FORWARD | head -1)"
echo "iptables: $(sudo iptables -V)"

standin() { sudo docker logs router-standin 2>&1 | grep -c ' accepted tcp:' || true; }
config() { # <auto-redirect true|false>
  jq -n --argjson redirect "$1" '{
    mode: "rule", "log-level": "info", ipv6: false,
    tun: {enable: true, stack: "mixed", "auto-route": true, "auto-redirect": $redirect,
          "auto-detect-interface": true, "dns-hijack": ["any:53", "tcp://any:53"], "exclude-uid": [65532]},
    dns: {enable: true, "enhanced-mode": "fake-ip", "fake-ip-range": "198.18.0.1/16",
          nameserver: ["https://1.1.1.1/dns-query"], "proxy-server-nameserver": ["system://"]},
    "proxy-providers": {dotdash: {type: "file", path: "/run/secrets/sub"}},
    "proxy-groups": [{name: "dotdash", type: "url-test", use: ["dotdash"],
      url: "https://www.gstatic.com/generate_204", interval: 300, "empty-fallback": "REJECT"}],
    rules: ["MATCH,dotdash"]}' | sudo tee "${dir}/etc/config.json" >/dev/null
  sudo chmod -R a+rX "${dir}/etc"
}
lan_curl() { # <URL>: status from the LAN device, and curl's exit code
  local out
  out=$(sudo ip netns exec lan curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 12 "$1" 2>&1)
  echo "${out} (exit $?)"
}
attempt() { # <name> <auto-redirect>
  echo "=== spike $1 (auto-redirect $2)"
  config "$2"
  sudo docker rm -f router-mihomo >/dev/null 2>&1
  sudo docker volume rm -f router-home >/dev/null 2>&1
  sudo docker run -d --name router-mihomo --network host --read-only --security-opt no-new-privileges:true \
    --cap-drop ALL --cap-add NET_ADMIN --cap-add DAC_OVERRIDE --user 0:0 --device /dev/net/tun \
    -v router-home:/var/lib/mihomo -v "${dir}/etc:/etc/mihomo:ro" -v "${dir}/secrets/sub:/run/secrets/sub:ro" \
    "${mihomo}" >/dev/null || { echo "  run refused"; return; }
  sleep 8
  echo "  state: $(sudo docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' router-mihomo)"
  sudo docker logs router-mihomo 2>&1 | grep -v '\[envconf\]' | grep -i -E 'tun|redirect|error|warn' | tail -6 | sed 's/^/  log: /'
  local before
  before=$(standin)
  echo "  rig itself: $(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 12 https://www.gstatic.com/generate_204); stand-in ${before} -> $(standin)"
  before=$(standin)
  echo "  LAN, by name: $(lan_curl https://www.gstatic.com/generate_204); stand-in ${before} -> $(standin)"
  before=$(standin)
  echo "  LAN, IP literal (1.1.1.1): $(lan_curl https://1.1.1.1/); stand-in ${before} -> $(standin)"
  echo "  LAN DNS: $(sudo ip netns exec lan nslookup www.example.com 1.1.1.1 2>&1 | tail -2 | tr '\n' ' ')"
  if [ "$2" = true ]; then
    echo "  nft tables: $(sudo nft list tables 2>&1 | tr '\n' ' ')"
    sudo nft list table inet mihomo 2>&1 | grep -i -E 'chain |forward|accept|redirect|hook' | head -24 | sed 's/^/    nft: /'
  fi
  echo "  FORWARD counters: $(sudo iptables -L FORWARD -v -n | head -3 | tr -s ' ' | tr '\n' ';')"
  sudo docker stop router-mihomo >/dev/null 2>&1
  sudo docker rm -f router-mihomo >/dev/null 2>&1
  sleep 2
}

# Round 1 ran with FORWARD policy ACCEPT (this rig's Docker left it): plain
# TUN, the accept rules and auto-redirect all carried the LAN device through
# dotdash. Round 2: DROP, as Docker sets it on many hosts.
sudo iptables -P FORWARD DROP
echo "FORWARD policy now: $(sudo iptables -S FORWARD | head -1)"
attempt tun-alone false
sudo iptables -I DOCKER-USER -i lanbr -j ACCEPT
sudo iptables -I DOCKER-USER -o lanbr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
attempt tun-docker-user-accept false
sudo iptables -D DOCKER-USER -i lanbr -j ACCEPT
sudo iptables -D DOCKER-USER -o lanbr -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
attempt auto-redirect true

sudo iptables -P FORWARD ACCEPT
sudo docker rm -f router-standin >/dev/null 2>&1
sudo ip netns del lan >/dev/null 2>&1
sudo ip link del lanbr >/dev/null 2>&1
echo "90-router-spike.sh: done (a spike: read the output above)"
exit 0
