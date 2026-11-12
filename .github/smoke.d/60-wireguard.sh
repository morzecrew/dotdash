#!/usr/bin/env bash
# A WireGuard line in the upstreams secret: the gate's own Xray WireGuard,
# from the wireguard:// line the wireguard-line task makes of a wg-quick file.
# A stand-in peer, the Xray image with a wireguard inbound, carries the rig's
# traffic on to the target. The line goes second, behind the rig's HTTP proxy:
#
# - wireguard-line turns a provider's wg-quick export into one line;
# - with that line behind the proxy, the proxy carries traffic;
# - with the proxy stopped, the WireGuard line carries a client and the
#   health check, and doctor passes;
# - with the peer stopped too, nothing gets through, and doctor names both
#   lines, the WireGuard one as such.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  wireguard-line:$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates WireGuard lines"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
target=http://11.99.0.10:8000/
keypair() {
  sudo docker run --rm --entrypoint /usr/local/bin/xray "${xray}" wg |
    awk -F': ' '/^PrivateKey/ { k = $2 } /PublicKey/ { p = $2 } END { print k, p }'
}
read -r peer_key peer_pub <<<"$(keypair)"
read -r client_key client_pub <<<"$(keypair)"

mkdir -p /rig/wgpeer
jq -n --arg key "${peer_key}" --arg pub "${client_pub}" '{log: {loglevel: "warning"},
  inbounds: [{listen: "0.0.0.0", port: 51820, protocol: "wireguard",
    settings: {secretKey: $key, peers: [{publicKey: $pub, allowedIPs: ["10.34.0.3/32"]}]}}],
  outbounds: [{protocol: "freedom"}]}' >/rig/wgpeer/config.json
chmod -R a+rX /rig/wgpeer
sudo docker rm -f dotdash-rig-wgpeer >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-wgpeer --network dotdash-rig -p 51820:51820/udp \
  -v /rig/wgpeer:/etc/xray:ro "${xray}" >/dev/null

one="http://$(cat /rig/upstream.conn) name=rig"
list() { printf '%s\n' "$@" | sudo morzer secret set upstreams >/dev/null; }
restore() {
  sudo docker rm -f dotdash-rig-wgclient >/dev/null 2>&1 || true
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  list "${one}" || true
  sudo docker rm -f dotdash-rig-wgpeer >/dev/null 2>&1 || true
}
trap restore EXIT

# A REALITY client of this hook's own, from the links as they are now:
# 45-revocation.sh rotates reality_key, which locks 10-clients.sh's out.
xray_client=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
link=$(sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality.*type=tcp') ||
  die "client-config printed no REALITY link"
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
rest=${link#vless://}
mkdir -p /rig/clients/wgclient
jq -n --arg id "${rest%%@*}" --arg enc "$(param "${link}" encryption)" --arg sni "$(param "${link}" sni)" \
  --arg pbk "$(param "${link}" pbk)" --arg sid "$(param "${link}" sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11096, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >/rig/clients/wgclient/client.json
chmod -R a+rX /rig/clients/wgclient
sudo docker rm -f dotdash-rig-wgclient >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-wgclient --network host -v /rig/clients/wgclient:/etc/xray:ro "${xray_client}" >/dev/null

body() { # <url>: through this hook's REALITY client; the body, or nothing
  curl -s --max-time 20 --retry 2 --retry-delay 2 --socks5-hostname 127.0.0.1:11096 "$1" 2>/dev/null || true
}
doctor() { { sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' '; }
# Up to 90 s: secret set returns once the gate restarts, before it serves,
# and a failover waits for the probes, every 30 s, to see the first line gone.
reaches() { # <url>: whether a client gets the target's "ok"
  local _
  for _ in $(seq 45); do [ "$(body "$1")" = ok ] && return 0; sleep 2; done
  return 1
}

# A provider's export: a DNS line, which the line leaves out.
printf '[Interface]\nPrivateKey = %s\nAddress = 10.34.0.3/32\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
  "${client_key}" "${peer_pub}" "${host}" | sudo tee /rig/wg0.conf >/dev/null
line=$(sudo morzer task run wireguard-line --output --input conf=/rig/wg0.conf | grep -m1 '^wireguard://') ||
  die "wireguard-line printed no wireguard:// line"
echo "${0##*/}: wireguard-line turns a wg-quick file into one line"

list "${one}" "${line} name=home"
reaches "${target}" || die "the proxy, first, does not carry traffic with the WireGuard line behind it"
echo "${0##*/}: the WireGuard line behind the proxy, and the proxy carries traffic"

sudo docker stop dotdash-rig-upstream >/dev/null
reaches "${target}" || die "with the proxy stopped, a client does not reach the target through the WireGuard line"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the WireGuard line carrying: $(doctor)"
echo "${0##*/}: with the proxy stopped, the WireGuard line carries a client and the health check"

sudo docker stop dotdash-rig-wgpeer >/dev/null
for _ in $(seq 20); do [ -z "$(body "${target}")" ] && break; sleep 3; done
[ -z "$(body "${target}")" ] || die "a client got through with the proxy and the WireGuard peer stopped"
out=$(doctor)
grep -q 'home (WireGuard): its peer did not carry it' <<<"${out}" || die "doctor does not name the WireGuard line: ${out}"
grep -q 'rig: cannot connect to' <<<"${out}" || die "doctor does not name the proxy line: ${out}"
sudo docker start dotdash-rig-wgpeer dotdash-rig-upstream >/dev/null
echo "${0##*/}: with both stopped, nothing gets through, and doctor names each line"
