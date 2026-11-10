#!/usr/bin/env bash
# A WireGuard upstream (upstream_protocol=wireguard): the gate's own Xray
# WireGuard, built from the wg-quick file in upstream_wireguard. A stand-in
# peer, the Xray image with a wireguard inbound, carries the rig's traffic on
# to the target, with the rig's HTTP proxy stopped so nothing can leave
# through it:
#
# - setting upstream_wireguard changes nothing while the proxy is the upstream;
# - with upstream_protocol=wireguard, apply's health check passes through the
#   peer, a client reaches the target, and doctor passes;
# - with the peer stopped, nothing gets through, and doctor names the peer;
# - upstream_protocol=http is one config set back to the proxy.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  - name: upstream_wireguard$' /opt/dotdash/current/secrets.schema.yaml; then
  echo "${0##*/}: skipped, the installed release predates the WireGuard upstream"
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

restore() {
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo morzer config set upstream_protocol=http >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-wgpeer >/dev/null 2>&1 || true
}
trap restore EXIT

body() { # <url>: through 10-clients.sh's REALITY client; the body, or nothing
  curl -s --max-time 20 --retry 2 --retry-delay 2 --socks5-hostname 127.0.0.1:11080 "$1" 2>/dev/null || true
}
doctor() { { sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' '; }
# Up to 30 s: secret set returns once the gate restarts, before it serves,
# and curl does not retry a refused connection.
reaches() { # <url>: whether a client gets the target's "ok"
  local _
  for _ in $(seq 15); do [ "$(body "$1")" = ok ] && return 0; sleep 2; done
  return 1
}

# A provider's export: a DNS line, which the gate leaves out.
printf '[Interface]\nPrivateKey = %s\nAddress = 10.34.0.3/32\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = %s\nEndpoint = %s:51820\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = 25\n' \
  "${client_key}" "${peer_pub}" "${host}" | sudo morzer secret set upstream_wireguard >/dev/null ||
  die "setting upstream_wireguard while the proxy is the upstream failed"
reaches "${target}" || die "the proxy stopped carrying traffic once upstream_wireguard was set"
echo "${0##*/}: upstream_wireguard set, and the proxy still the upstream"

sudo docker stop dotdash-rig-upstream >/dev/null
sudo morzer config set upstream_protocol=wireguard >/dev/null ||
  die "could not switch to the WireGuard upstream (its health check failed?)"
reaches "${target}" || die "a client does not reach the target through the WireGuard upstream"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the WireGuard peer answering: $(doctor)"
echo "${0##*/}: with the proxy stopped, the WireGuard upstream carries the health check and a client"

sudo docker stop dotdash-rig-wgpeer >/dev/null
[ -z "$(body "${target}")" ] || die "a client got through with the WireGuard peer stopped"
grep -q 'the WireGuard peer in the upstream_wireguard secret did not carry it' <<<"$(doctor)" ||
  die "doctor does not name the WireGuard peer with it stopped"
sudo docker start dotdash-rig-wgpeer >/dev/null
echo "${0##*/}: with the peer stopped, nothing gets through, and doctor names it"

sudo docker start dotdash-rig-upstream >/dev/null
sudo morzer config set upstream_protocol=http >/dev/null || die "could not switch back to the proxy"
reaches "${target}" || die "a client does not reach the target back on the proxy"
echo "${0##*/}: upstream_protocol=http is one config set back to the proxy"
