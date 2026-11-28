#!/usr/bin/env bash
# What a real relay has and this rig does not: a dotdash server group to carry
# devices on to. A stand-in Xray serves REALITY on the rig's port 9443 (the
# relay itself holds 443), with keys made here, borrowing www.gstatic.com's
# handshake, and XHTTP with REALITY on 9444, for server_link=xhttp-reality,
# under the path in /rig/relay/xhttp_path; it lets traffic straight out. It
# lets the relay in by the id a server derives from its relay_seed and the
# relay's name and nonce (the image's relay-id), as relay-r1, and hands that
# user alone the internal names *.sub.dotdash.internal, on to a stand-in for
# the server's internal listener (busybox httpd): the relay's device list at
# its list token, with the rig's one device, phone, whose id the later hooks
# read from /rig/relay/device, and phone's subscription at its token
# (/rig/relay/token). The relay reaches the server on the rig's docker0
# address; its servers secret is the server/1 line relay-config would print,
# group s1, which the later hooks read from /rig/relay/server-line. It needs
# the internet, which a GitHub-hosted runner has.
#
# smoke-update installs the published release first, which is the one before
# the gateway until this one is published: it gets the servers' keys and its
# copy of the devices by hand, as that release took them.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
[ -n "${xray}" ] && [ -n "${busybox}" ] || die "the bundle's pinned xray and busybox images are not in the rig"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
sid=$(openssl rand -hex 8)
path=$(openssl rand -hex 16)
device=$(cat /proc/sys/kernel/random/uuid)
mkdir -p /rig/relay/server /rig/relay/web
printf %s "${device}" >/rig/relay/device
printf %s "${path}" >/rig/relay/xhttp_path

if sudo morzer config get dotdash_port >/dev/null 2>&1; then
  # The release before the gateway: its own client of the server, and a copy
  # of the devices.
  id=$(cat /proc/sys/kernel/random/uuid)
  clients=$(jq -nc --arg id "${id}" '[{id: $id, flow: "xtls-rprx-vision"}]')
  sudo morzer config set "dotdash_address=${host}" dotdash_port=9443 "dotdash_public_key=${public}" >/dev/null
  printf %s "${id}" | sudo morzer secret set dotdash_id >/dev/null
  printf none | sudo morzer secret set dotdash_encryption >/dev/null
  printf %s "${sid}" | sudo morzer secret set dotdash_short_id >/dev/null
  printf '%s phone\n' "${device}" | sudo morzer secret set vless_clients >/dev/null
else
  # The relay's id on the stand-in group, from its name and the nonce init
  # generated, rendered here before the first apply; and its list there.
  sudo morzer secret render >/dev/null
  name=$(sudo morzer config get name)
  nonce=$(sudo cat /run/dotdash-relay/secrets/nonce)
  openssl rand -hex 32 | tr -d '\n' >/rig/relay/server/seed
  chmod a+r /rig/relay/server/seed
  id=$(sudo docker run --rm -v /rig/relay/server/seed:/seed:ro "${xray}" relay-id /seed "${name}" "${nonce}")
  [ -n "${id}" ] || die "relay-id printed no id"
  clients=$(jq -nc --arg id "${id}" --arg n "relay-${name}" '[{id: $id, email: $n, flow: "xtls-rprx-vision"}]')
  token=$(openssl rand -hex 16)
  printf %s "${token}" >/rig/relay/token
  printf '# dotdash relay list v1\n%s phone %s\n' "${device}" "${token:0:12}" \
    >"/rig/relay/web/$(printf '%s:list' "${id}" | sha256sum | cut -c1-32)"
  printf 'subscription of phone' >"/rig/relay/web/${token}"
  printf '{"subscription_of": "phone"}' >"/rig/relay/web/${token}.json"
  line="server/1 s1 www.gstatic.com 9443 ${public} ${sid} none ${id} xr=9444,${path} address=${host}"
  printf '%s\n' "${line}" >/rig/relay/server-line
  printf '%s\n' "${line}" | sudo morzer secret set servers >/dev/null
fi

# The stand-in server; its internal names go to the stand-in listener, for a
# relay's user alone, as a server's Xray hands them to its Caddy: a private
# address, which freedom refuses unless a final rule allows it.
jq -n --argjson clients "${clients}" --arg key "${private}" --arg sid "${sid}" --arg path "${path}" '
  {log: {loglevel: "warning"},
   inbounds: [{listen: "0.0.0.0", port: 9443, protocol: "vless",
     settings: {clients: $clients, decryption: "none"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}},
    {listen: "0.0.0.0", port: 9444, protocol: "vless",
     settings: {clients: ($clients | map(del(.flow))), decryption: "none"},
     streamSettings: {network: "xhttp", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]},
       xhttpSettings: {path: $path, mode: "auto"}}}],
   outbounds: [{protocol: "freedom"},
     {tag: "sub", protocol: "freedom", settings: {redirect: "relay-rig-web:8085", finalRules: [{action: "allow"}]}},
     {tag: "block", protocol: "blackhole"}],
   routing: {rules: [{domain: ["domain:sub.dotdash.internal"], user: ["regexp:^relay-"], outboundTag: "sub"},
     {domain: ["domain:sub.dotdash.internal"], outboundTag: "block"}]}}' >/rig/relay/server/config.json
chmod -R a+rX /rig/relay/server /rig/relay/web
sudo docker network create relay-rig >/dev/null
sudo docker run -d --name relay-rig-web --network relay-rig -v /rig/relay/web:/www:ro "${busybox}" \
  httpd -f -p 8085 -h /www >/dev/null
sudo docker run -d --name relay-rig-server --network relay-rig -p 9443:9443 -p 9444:9444 \
  -v /rig/relay/server/config.json:/etc/xray/config.json:ro "${xray}" >/dev/null

# smoke-update's pre-update backup would capture nothing: no volume, and no
# identity without a recovery key, which the rig's init skips.
sudo morzer config set backup.before_update=false
