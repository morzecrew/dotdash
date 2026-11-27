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

xray=ghcr.io/morzecrew/xray:26.11.9@sha256:f9651c4e3bb6732824dacead53936dccf26ec6a59b0db763bda175b9ebe359a3
caddy=ghcr.io/morzecrew/caddy-acmedns:2.11.9@sha256:b4f05d7f209104f193bae71cd62529bdb428257fcd623b04306e85e5382eccc2
sudo docker pull -q "${xray}" >/dev/null || die "pulling ${xray} failed"
sudo docker pull -q "${caddy}" >/dev/null || die "pulling ${caddy} failed"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
id=$(cat /proc/sys/kernel/random/uuid)
sid=$(openssl rand -hex 8)

# VLESS Encryption from a seed, as dotdash's REALITY inbound has it: the
# image derives the server's key from the file, and prints the client's.
mkdir -p /rig/client/server /rig/client/secrets /rig/client/www /rig/client/caddy
openssl rand -hex 64 >/rig/client/secrets/vless_seed
chmod -R a+rX /rig/client/secrets
enc=$(sudo docker run --rm --entrypoint /usr/local/bin/xray-entrypoint -v /rig/client/secrets:/run/secrets:ro \
  "${xray}" vless-encryption /run/secrets/vless_seed)
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" '
  {log: {loglevel: "warning", access: ""},
   inbounds: [{listen: "0.0.0.0", port: 9443, protocol: "vless",
     settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: {"$vlessDecryption": "/run/secrets/vless_seed"}},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}}],
   outbounds: [{protocol: "freedom", settings: {finalRules: [{action: "allow", ip: ["172.16.0.0/12", "192.168.0.0/16"]}]}}]}' \
  >/rig/client/server/config.json
# The link and outbounds are dotdash's own: server.txt is client-config's
# output for a server on 9443 under www.gstatic.com, its values left out
# (.github/tests/client-config.sh holds it to that), and these fill them in.
fill() { sed "s|{id}|${id}|g; s|{host}|${host}|g; s|{enc}|${enc}|g; s|{pbk}|${public}|g; s|{sid}|${sid}|g" "${0%/*}/server.txt"; }
fill | sed -n 1p | base64 -w0 >/rig/client/www/sub
fill | sed -n 2p | jq '{outbounds: .}' >/rig/client/www/sub.json
[ -s /rig/client/www/sub ] && jq -e '.outbounds[0].tag == "dotdash-1-reality"' /rig/client/www/sub.json >/dev/null ||
  die "server.txt holds no REALITY link and outbounds"
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
sudo docker run -d --name client-rig-server -p 9443:9443 -v /rig/client/server:/etc/xray:ro \
  -v /rig/client/secrets:/run/secrets:ro "${xray}" >/dev/null
sudo docker run -d --name client-rig-sub -p 8088:8080 -v /rig/client/caddy:/etc/caddy:ro -v /rig/client/www:/www:ro \
  "${caddy}" >/dev/null

printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
# smoke-update's pre-update backup would capture nothing: no volume worth
# keeping, and no identity without a recovery key, which the rig's init skips.
sudo morzer config set backup.before_update=false
