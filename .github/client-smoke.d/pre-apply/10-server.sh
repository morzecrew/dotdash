#!/usr/bin/env bash
# What a real client machine has and this rig does not: a dotdash server and
# a subscription to its links. A stand-in Xray serves REALITY on the rig's port
# 9443, with keys made here, borrowing www.gstatic.com's handshake, and lets
# traffic straight out, to the rig's private addresses too, which Xray's
# freedom refuses VLESS traffic by default (15-refresh.sh needs them). busybox
# httpd serves a subscription of its one link on 8088, logging each request's
# address (15-refresh.sh reads it). The client reaches both on the rig's
# docker0 address. The workflows' init gave smoke.sh's random secrets; this
# sets the subscription URL. It needs the internet, which a GitHub-hosted
# runner has.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=ghcr.io/morzecrew/xray:26.11.9@sha256:9d6c0112c03e921a786f9cbaf2efd65e89bf0bbd7027015b81abb535c58a2d19
busybox=docker.io/library/busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec
sudo docker pull -q "${xray}" >/dev/null || die "pulling ${xray} failed"
sudo docker pull -q "${busybox}" >/dev/null || die "pulling ${busybox} failed"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
id=$(cat /proc/sys/kernel/random/uuid)
sid=$(openssl rand -hex 8)

mkdir -p /rig/client/server /rig/client/www
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" '
  {log: {loglevel: "warning", access: ""},
   inbounds: [{listen: "0.0.0.0", port: 9443, protocol: "vless",
     settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}}],
   outbounds: [{protocol: "freedom", settings: {finalRules: [{action: "allow", ip: ["172.16.0.0/12", "192.168.0.0/16"]}]}}]}' \
  >/rig/client/server/config.json
# As dotdash's client-config prints a REALITY link, mihomo's key share included.
printf 'vless://%s@%s:9443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.gstatic.com&fp=chrome&pbk=%s&sid=%s&support-x25519mlkem768=true&type=tcp#stand-in%%20%%5Breality%%5D\n' \
  "${id}" "${host}" "${public}" "${sid}" | base64 -w0 >/rig/client/www/sub
chmod -R a+rX /rig/client
sudo docker run -d --name client-rig-server -p 9443:9443 -v /rig/client/server:/etc/xray:ro "${xray}" >/dev/null
sudo docker run -d --name client-rig-sub -p 8088:8080 -v /rig/client/www:/www:ro "${busybox}" \
  httpd -f -v -p 8080 -h /www >/dev/null

printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
# smoke-update's pre-update backup would capture nothing: no volume worth
# keeping, and no identity without a recovery key, which the rig's init skips.
sudo morzer config set backup.before_update=false
