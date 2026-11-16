#!/usr/bin/env bash
# What a real client machine has and this rig does not: a dotdash server and
# a subscription to its links. A stand-in Xray serves REALITY on the rig's port
# 9443, with keys made here, borrowing www.gstatic.com's handshake, and lets
# traffic straight out, to the rig's private addresses too, which Xray's
# freedom refuses VLESS traffic by default (15-refresh.sh needs them). Caddy
# serves a subscription of its one link on 8088, and its Xray config, the
# outbounds client-config prints, to a request with Accept: application/json,
# as a dotdash server does (the published client that smoke-update installs
# first reads the links, this one the config). It logs each request's address
# (15-refresh.sh reads it). The client reaches both on the rig's docker0
# address. The workflows' init gave smoke.sh's random secrets; this sets the
# subscription URL. It needs the internet, which a GitHub-hosted runner has.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=ghcr.io/morzecrew/xray:26.11.9@sha256:389e5c9713cd64e8cbb12c95df482bc14918fe7e95eb5ec57f5ff3496a3ea9b7
caddy=ghcr.io/morzecrew/caddy-acmedns:2.11.9@sha256:93c19f705c2218d5fca7f7dcb694cae1ed3889588678aabb7af34c8892e2f2bb
sudo docker pull -q "${xray}" >/dev/null || die "pulling ${xray} failed"
sudo docker pull -q "${caddy}" >/dev/null || die "pulling ${caddy} failed"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
id=$(cat /proc/sys/kernel/random/uuid)
sid=$(openssl rand -hex 8)

mkdir -p /rig/client/server /rig/client/www /rig/client/caddy
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" '
  {log: {loglevel: "warning", access: ""},
   inbounds: [{listen: "0.0.0.0", port: 9443, protocol: "vless",
     settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}}],
   outbounds: [{protocol: "freedom", settings: {finalRules: [{action: "allow", ip: ["172.16.0.0/12", "192.168.0.0/16"]}]}}]}' \
  >/rig/client/server/config.json
# As dotdash's client-config prints a REALITY link, and its outbound.
printf 'vless://%s@%s:9443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.gstatic.com&fp=chrome&pbk=%s&sid=%s&support-x25519mlkem768=true&type=tcp#stand-in%%20%%5Breality%%5D\n' \
  "${id}" "${host}" "${public}" "${sid}" | base64 -w0 >/rig/client/www/sub
jq -n --arg id "${id}" --arg host "${host}" --arg key "${public}" --arg sid "${sid}" '
  {outbounds: [{tag: "dotdash-1-reality", protocol: "vless",
     settings: {address: $host, port: 9443, id: $id, encryption: "none", flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: "www.gstatic.com", fingerprint: "chrome", password: $key, shortId: $sid}}},
   {tag: "dns-out", protocol: "dns"}]}' >/rig/client/www/sub.json
cat >/rig/client/caddy/Caddyfile <<'EOF'
{
	admin off
	auto_https off
}
:8080 {
	log
	root * /www
	@json header Accept application/json
	rewrite @json {path}.json
	file_server
}
EOF
chmod -R a+rX /rig/client
sudo docker run -d --name client-rig-server -p 9443:9443 -v /rig/client/server:/etc/xray:ro "${xray}" >/dev/null
sudo docker run -d --name client-rig-sub -p 8088:8080 -v /rig/client/caddy:/etc/caddy:ro -v /rig/client/www:/www:ro \
  "${caddy}" >/dev/null

printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
# smoke-update's pre-update backup would capture nothing: no volume worth
# keeping, and no identity without a recovery key, which the rig's init skips.
sudo morzer config set backup.before_update=false
