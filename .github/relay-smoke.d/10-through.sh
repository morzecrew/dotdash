#!/usr/bin/env bash
# The relay's promise: a device listed in vless_clients, holding the line
# relay-entry prints, gets out through the relay and on through dotdash (the
# stand-in, pre-apply/10-server.sh); one that is not listed gets nothing. The
# device is an Xray client on the rig, as the link dotdash would print makes it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
entry=$(sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^127\.0\.0\.1 ' || true)
[ -n "${entry}" ] || die "relay-entry printed no line for 127.0.0.1"
read -r host site pbk sid enc <<<"${entry}"
[ "${site}" = www.gstatic.com ] || die "relay-entry gave the site as ${site}"

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

device phone 18081 "$(cat /rig/relay/device)"
code=$(fetch 18081)
[ "${code}" = 204 ] || die "a listed device got ${code} through the relay, not 204"

device stranger 18082 "$(cat /proc/sys/kernel/random/uuid)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --proxy http://127.0.0.1:18082 \
  https://www.gstatic.com/generate_204 || true)
[ "${code}" != 204 ] || die "a device missing from vless_clients got through the relay"
sudo docker rm -f relay-rig-stranger >/dev/null
echo "10-through.sh: a listed device gets out through the relay and dotdash; an unlisted one does not"

# ipv6=block: IPv6 destinations end at the relay, in a blackhole after the
# servers' outbounds, and the listed device still gets out by name.
if sudo grep -q '^  ipv6:$' /opt/dotdash-relay/current/manifest.yaml; then
  sudo morzer config set ipv6=block >/dev/null || die "could not set ipv6=block"
  sudo jq -e '.outbounds[-1] == {tag: "block", protocol: "blackhole"} and .outbounds[0].tag == "dotdash-0"
    and .routing.rules[0] == {type: "field", ip: ["::/0"], outboundTag: "block"}' \
    /etc/dotdash-relay/xray.json >/dev/null ||
    { sudo morzer config set ipv6=allow >/dev/null 2>&1 || true
      die "ipv6=block did not end IPv6 in a blackhole: $(sudo jq -c '{outbounds: [.outbounds[].tag], routing}' /etc/dotdash-relay/xray.json)"; }
  code=$(fetch 18081)
  sudo morzer config set ipv6=allow >/dev/null || die "could not set ipv6=allow"
  [ "${code}" = 204 ] || die "with ipv6=block the listed device got ${code}, not 204"
  sudo jq -e '.routing == null and ([.outbounds[].tag] | index("block") == null)' /etc/dotdash-relay/xray.json >/dev/null ||
    die "back on ipv6=allow, the block remains"
  echo "10-through.sh: ipv6=block ends IPv6 at the relay, and the device still gets out"
fi
sudo docker rm -f relay-rig-phone >/dev/null
