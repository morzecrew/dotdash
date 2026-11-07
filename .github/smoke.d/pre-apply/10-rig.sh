#!/usr/bin/env bash
# What a real machine has before its first apply and this rig does not: an
# upstream proxy, and the URL the healthcheck fetches through it. The workflows'
# init-args already gave init the domain, every other upstream setting, that
# URL (http://target:8000/) and cert_issuer=internal, which needs no Let's
# Encrypt; only the upstream's address is known no earlier than here.
#
# The upstream is an Xray HTTP proxy with no accounts, so it ignores the
# random credentials smoke.sh set. It shares a network with the healthcheck's
# target, which only it resolves; the bundle's Xray reaches it on the rig's
# docker0 address. Both run images the bundle pins, already in the rig.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

pinned() { sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' "$1" | sed -n 1p; }
xray=$(pinned ghcr.io/morzecrew/xray)
caddy=$(pinned caddy)
[ -n "${xray}" ] && [ -n "${caddy}" ] || die "the bundle's pinned images are not in the rig"
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')

mkdir -p /rig/upstream
cat >/rig/upstream/upstream.json <<'EOF'
{"inbounds": [{"listen": "0.0.0.0", "port": 8080, "protocol": "http"}], "outbounds": [{"protocol": "freedom"}]}
EOF
chmod -R a+rX /rig/upstream
sudo docker network create dotdash-rig >/dev/null
sudo docker run -d --name dotdash-rig-target --network dotdash-rig --network-alias target \
  "${caddy}" caddy respond --listen :8000 ok >/dev/null
sudo docker run -d --name dotdash-rig-upstream --network dotdash-rig -p 18080:8080 \
  -v /rig/upstream:/etc/xray:ro "${xray}" >/dev/null

sudo morzer config set "upstream_host=${host}"
