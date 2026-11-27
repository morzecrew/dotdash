#!/usr/bin/env bash
# The relay's promise: a device in its server group's list, holding the
# relay/1 line relay-entry prints, gets out through the relay and on through
# its group's server (the stand-in, pre-apply/10-server.sh), with no restart
# to let it in; one in no list gets nothing. The device is an Xray client on
# the rig, as the link its server would print makes it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
entry=$(sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^relay/1 ' || true)
[ -n "${entry}" ] || die "relay-entry printed no relay/1 line"
read -r _ name nonce host site pbk sid enc _ <<<"${entry}"
[ "${name} ${host} ${site}" = "r1 127.0.0.1 www.gstatic.com" ] || die "relay-entry's line is not relay/1 r1 <nonce> 127.0.0.1 www.gstatic.com …"
[[ ${nonce} =~ ^[0-9a-f]{16}$ ]] || die "relay-entry's nonce is not 16 hex characters"

device() { # <name> <port> <id>: an Xray client of the relay, HTTP proxy on 127.0.0.1:<port>
  mkdir -p "/rig/relay/$1"
  jq -n --arg host "${host}" --arg site "${site}" --arg pbk "${pbk}" --arg sid "${sid}" --arg enc "${enc}" \
    --arg id "$3" --argjson port "$2" '
    {inbounds: [{listen: "127.0.0.1", port: $port, protocol: "http"}],
     outbounds: [{protocol: "vless",
       settings: {address: $host, port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
       streamSettings: {network: "raw", security: "reality", realitySettings:
         {serverName: $site, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >"/rig/relay/$1/config.json"
  chmod -R a+rX "/rig/relay/$1"
  sudo docker rm -f "relay-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "relay-rig-$1" --network host -v "/rig/relay/$1:/etc/xray:ro" "${xray}" >/dev/null
}
fetch() { # <port>: the status of probe_url through that device, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --proxy "http://127.0.0.1:$1" https://www.gstatic.com/generate_204 || true
}
# How many times Xray has started in this container: the gateway's agent
# restarts it in place, which the container's own start time doesn't show.
starts() { sudo docker logs "$(service_container xray)" 2>&1 | grep -c 'core: Xray .* started' || true; }

# The agent's first round has the list a second after Xray starts.
since=$(starts)
device phone 18081 "$(cat /rig/relay/device)"
code=$(fetch 18081)
[ "${code}" = 204 ] || die "a device in its group's list got ${code} through the relay, not 204: $(sudo morzer task run servers --output 2>&1 || true)"
[ "$(starts)" = "${since}" ] || die "Xray restarted to let the device in"

device stranger 18082 "$(cat /proc/sys/kernel/random/uuid)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --proxy http://127.0.0.1:18082 \
  https://www.gstatic.com/generate_204 || true)
[ "${code}" != 204 ] || die "a device in no list got through the relay"
sudo docker rm -f relay-rig-stranger >/dev/null
echo "${0##*/}: a device in its group's list gets out through the relay and its server, with no restart; one in none does not"

# ipv6=block: IPv6 destinations end at the relay, by the gateway's first
# rule, and the listed device still gets out by name.
rules() { sudo docker exec "$(service_container xray)" /usr/local/bin/xray api lsrules --server=127.0.0.1:10085 | jq -c '[.rules[].ruleTag]'; }
sudo morzer config set ipv6=block >/dev/null || die "could not set ipv6=block"
got=$(rules)
jq -e '.[0] == "ipv6" and .[-1] == "block"' <<<"${got}" >/dev/null ||
  { sudo morzer config set ipv6=allow >/dev/null 2>&1 || true; die "ipv6=block did not end IPv6 at the relay first: ${got}"; }
code=$(fetch 18081)
sudo morzer config set ipv6=allow >/dev/null || die "could not set ipv6=allow"
[ "${code}" = 204 ] || die "with ipv6=block the listed device got ${code}, not 204"
got=$(rules)
jq -e 'index("ipv6") == null and .[0] == "internal" and .[-1] == "block"' <<<"${got}" >/dev/null ||
  die "back on ipv6=allow, the rules are not internal … block: ${got}"
echo "${0##*/}: ipv6=block ends IPv6 at the relay, and the device still gets out"
# The relay ends devices' TCP, so it sends their downloads, on BBR in its own
# namespace (tcp_congestion); running at all is the kernel's acceptance.
cc=$(sudo docker inspect -f '{{index .HostConfig.Sysctls "net.ipv4.tcp_congestion_control"}}' "$(service_container xray)")
[ "${cc}" = bbr ] || die "the relay's congestion control is '${cc}', not bbr"
[ "$(fetch 18081)" = 204 ] || die "the listed device does not get out with the relay on BBR"
echo "${0##*/}: the relay sends on BBR in its own namespace"
sudo docker rm -f relay-rig-phone >/dev/null
