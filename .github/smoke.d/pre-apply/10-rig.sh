#!/usr/bin/env bash
# What a real machine has before its first apply and this rig does not: an
# upstream proxy, and the URL the healthcheck fetches through it. The workflows'
# init-args already gave init the domain, the upstream's protocol, that URL
# (http://11.99.0.10:8000/) and cert_issuer=internal, which needs no Let's
# Encrypt; only the upstream's address is known no earlier than here.
#
# The target has a fixed address in a subnet that is not private (11.99.0.0/24,
# never routed publicly), so the hooks reach it by address: with resolve=gateway,
# the default, Xray resolves names itself and blocks private addresses, and a
# name only the rig knows would resolve nowhere. 35-resolve.sh uses the name
# `target`, which the upstream resolves, to show what resolve=upstream hands it.
#
# The upstream is an Xray HTTP proxy with one account, which replaces the
# random value smoke.sh set, so a later hook can break the credentials on
# purpose (/rig/upstream.conn keeps the right "user:pass@host:port", and
# /rig/upstream.pass the password alone, for a release before it). It
# shares a network with the healthcheck's target, which only it resolves; the
# bundle's Xray reaches it on the rig's docker0 address. The target also stands in for the
# IP-echo and network-lookup services exit-check asks, and serves /blob for
# the benchmark. Both run images the bundle pins, already in the rig.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

pinned() { sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' "$1" | sed -n 1p; }
xray=$(pinned ghcr.io/morzecrew/xray)
# The bundle's Caddy: caddy-acmedns, or upstream's in a release before it,
# which the rehearsal installs first.
caddy=$(pinned ghcr.io/morzecrew/caddy-acmedns)
[ -n "${caddy}" ] || caddy=$(pinned caddy)
[ -n "${xray}" ] && [ -n "${caddy}" ] || die "the bundle's pinned images are not in the rig"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

mkdir -p /rig/upstream /rig/target /rig/upstream-log
pass=$(random)
printf 'rig:%s@%s:18080' "${pass}" "${host}" >/rig/upstream.conn
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
chmod a+r /rig/upstream.conn /rig/upstream.pass
sudo docker network create --subnet 11.99.0.0/24 dotdash-rig >/dev/null
sudo docker run -d --name dotdash-rig-target --network dotdash-rig --ip 11.99.0.10 --network-alias target \
  -v /rig/target:/etc/caddy:ro "${caddy}" >/dev/null
sudo docker run -d --name dotdash-rig-upstream --network dotdash-rig -p 18080:8080 \
  -v /rig/upstream:/etc/xray:ro -v /rig/upstream-log:/log "${xray}" >/dev/null

# Before the first apply morzer has nothing to restart, and says so. The list
# is what this release reads; the line alone is what a release before it read,
# which smoke-update installs first, and which keeps the list for its update.
printf 'http://%s name=rig\n' "$(cat /rig/upstream.conn)" | sudo morzer secret set upstreams >/dev/null 2>&1 || true
printf "%s" "$(cat /rig/upstream.conn)" | sudo morzer secret set upstream >/dev/null 2>&1 || true
# A release from before the upstream secret, which smoke-update installs
# first, takes a host and a port parameter and two secrets instead. Only such
# a release accepts upstream_host; the secret above it ignores.
if sudo morzer config set "upstream_host=${host}" upstream_port=18080 >/dev/null 2>&1; then
  printf rig | sudo morzer secret set upstream_username >/dev/null 2>&1 || true
  printf '%s' "${pass}" | sudo morzer secret set upstream_password >/dev/null 2>&1 || true
fi
