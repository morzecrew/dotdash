#!/usr/bin/env bash
# What a real machine has before its first apply and this rig does not: an
# upstream proxy, and the URL the healthcheck fetches through it. The workflows'
# init-args already gave init the domain, every other upstream setting, that
# URL (http://11.99.0.10:8000/) and cert_issuer=internal, which needs no Let's
# Encrypt; only the upstream's address is known no earlier than here.
#
# The target has a fixed address in a subnet that is not private (11.99.0.0/24,
# never routed publicly), so the hooks reach it by address: with resolve=gateway,
# the default, Xray resolves names itself and blocks private addresses, and a
# name only the rig knows would resolve nowhere. 35-resolve.sh uses the name
# `target`, which the upstream resolves, to show what resolve=upstream hands it.
#
# The upstream is an Xray HTTP proxy with one account, whose credentials
# replace the random ones smoke.sh set, so a later hook can break them on
# purpose (/rig/upstream.pass keeps the right password). It shares a network
# with the healthcheck's target, which only it resolves; the bundle's Xray
# reaches it on the rig's docker0 address. The target also stands in for the
# IP-echo and network-lookup services exit-check asks, and serves /blob for
# the benchmark. Both run images the bundle pins, already in the rig.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

pinned() { sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' "$1" | sed -n 1p; }
xray=$(pinned ghcr.io/morzecrew/xray)
caddy=$(pinned caddy)
[ -n "${xray}" ] && [ -n "${caddy}" ] || die "the bundle's pinned images are not in the rig"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

mkdir -p /rig/upstream /rig/target /rig/upstream-log
pass=$(random)
printf '%s' "${pass}" >/rig/upstream.pass
# It logs every destination it is asked for (35-resolve.sh reads them).
jq -n --arg pass "${pass}" '{log: {access: "/log/access.log", loglevel: "warning"},
  inbounds: [{listen: "0.0.0.0", port: 8080, protocol: "http",
  settings: {accounts: [{user: "rig", pass: $pass}]}}], outbounds: [{protocol: "freedom"}]}' \
  >/rig/upstream/upstream.json
chmod 0777 /rig/upstream-log
cat >/rig/target/Caddyfile <<'EOF'
{
	admin off
}
:8000 {
	respond /ip4 "203.0.113.7"
	respond /ip6 "2001:db8::7"
	respond /info/203.0.113.7/org "AS64500 Rig Network"
	respond /info/203.0.113.7/country "ZZ"
	respond /info/2001:db8::7/org "AS64501 Other Network"
	respond /info/2001:db8::7/country "YY"
	handle /blob {
		root * /etc/caddy
		file_server
	}
	respond "ok"
}
EOF
# 1 MiB for the benchmark's transfers (.github/bench).
head -c 1048576 /dev/urandom >/rig/target/blob
chmod -R a+rX /rig/upstream /rig/target
chmod a+r /rig/upstream.pass
sudo docker network create --subnet 11.99.0.0/24 dotdash-rig >/dev/null
sudo docker run -d --name dotdash-rig-target --network dotdash-rig --ip 11.99.0.10 --network-alias target \
  -v /rig/target:/etc/caddy:ro "${caddy}" >/dev/null
sudo docker run -d --name dotdash-rig-upstream --network dotdash-rig -p 18080:8080 \
  -v /rig/upstream:/etc/xray:ro -v /rig/upstream-log:/log "${xray}" >/dev/null

sudo morzer config set "upstream_host=${host}"
# Before the first apply morzer has nothing to restart, and says so.
printf rig | sudo morzer secret set upstream_username >/dev/null 2>&1 || true
printf '%s' "${pass}" | sudo morzer secret set upstream_password >/dev/null 2>&1 || true
