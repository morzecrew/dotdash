#!/usr/bin/env bash
# What a real canary machine has and this rig does not: a dotdash server to get
# out through. A stand-in Xray serves REALITY on the rig's port 443, XHTTP
# with REALITY on 8443 (30-xhttp-reality.sh), mKCP on 8447/udp
# (31-mkcp.sh) and Hysteria2 on 443/udp (32-hysteria2.sh, under a self-signed
# certificate it pins), with keys made here, borrowing
# www.gstatic.com's handshake, and lets the probe straight out, to the rig's
# own addresses too (25-facts.sh's stand-in freeze_url), which Xray's freedom
# refuses unless a final rule allows them; the canary reaches it on the rig's
# docker0 address. The workflows'
# init-args gave init placeholders and smoke.sh random secrets; this sets the
# real ones. It needs the internet, which a GitHub-hosted runner has.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
[ -n "${xray}" ] || die "the bundle's pinned xray image is not in the rig"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
id=$(cat /proc/sys/kernel/random/uuid)
sid=$(openssl rand -hex 8)
path=$(random)
seed=$(openssl rand -hex 16)

mkdir -p /rig/server
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=www.gstatic.com \
  -addext subjectAltName=DNS:www.gstatic.com -keyout /rig/server/hy2.key -out /rig/server/hy2.crt 2>/dev/null
openssl x509 -in /rig/server/hy2.crt -noout -fingerprint -sha256 | sed 's/^.*=//' >/rig/hy2-pin
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" --arg path "/${path}" --arg seed "${seed}" '
  {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]} as $reality
  | {inbounds: [
      {listen: "0.0.0.0", port: 443, protocol: "vless",
       settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
       streamSettings: {network: "raw", security: "reality", realitySettings: $reality}},
      {listen: "0.0.0.0", port: 8443, protocol: "vless",
       settings: {clients: [{id: $id}], decryption: "none"},
       streamSettings: {network: "xhttp", security: "reality", realitySettings: $reality,
         xhttpSettings: {path: $path, mode: "auto"}}},
      {listen: "0.0.0.0", port: 8447, protocol: "vless",
       settings: {clients: [{id: $id}], decryption: "none"},
       streamSettings: {network: "kcp", finalmask: {udp: [
         {type: "mkcp-legacy", settings: {value: $seed}}, {type: "mkcp-legacy", settings: {header: "dtls"}}]}}},
      {listen: "0.0.0.0", port: 8448, protocol: "hysteria",
       settings: {version: 2, users: [{auth: $id}]},
       streamSettings: {network: "hysteria", security: "tls",
         tlsSettings: {alpn: ["h3"], certificates: [{certificateFile: "/etc/xray/hy2.crt", keyFile: "/etc/xray/hy2.key"}]},
         hysteriaSettings: {version: 2}}}],
    outbounds: [{protocol: "freedom",
      settings: {finalRules: [{action: "allow", ip: ["172.16.0.0/12", "10.0.0.0/8", "192.168.0.0/16"]}]}}]}' \
  >/rig/server/config.json
chmod -R a+rX /rig/server
sudo docker run -d --name canary-rig-server -p 443:443 -p 8443:8443 -p 8447:8447/udp -p 443:8448/udp --sysctl net.ipv4.ip_unprivileged_port_start=0 \
  -v /rig/server:/etc/xray:ro "${xray}" >/dev/null

sudo morzer config set "dotdash_address=${host}"
sudo morzer config set "dotdash_public_key=${public}"
printf %s "${id}" | sudo morzer secret set dotdash_id >/dev/null
printf none | sudo morzer secret set dotdash_encryption >/dev/null
printf %s "${sid}" | sudo morzer secret set dotdash_short_id >/dev/null
printf %s "${path}" | sudo morzer secret set dotdash_xhttp_path >/dev/null
printf %s "${seed}" | sudo morzer secret set dotdash_kcp_seed >/dev/null
# smoke-update's pre-update backup would capture nothing: no volume, and no
# identity without a recovery key, which the rig's init skips. A real canary
# has a recovery key (canary-config prints it).
sudo morzer config set backup.before_update=false
