#!/bin/sh
# Caddy's start: XRAY_NET, the address ranges of the backend network, which
# Caddy shares with Xray alone, for the Caddyfile's PROXY protocol on 443.
# Caddy's other network, edge, holds its default route; backend, internal,
# holds none, so it is what is left. With nothing left, loopback: no header
# is taken, and the cover app sees Xray's address, as it did.
set -eu
dev=$(ip -4 route show default | awk '{ print $5; exit }')
XRAY_NET=$({ ip -4 route; ip -6 route 2>/dev/null || true; } |
  awk -v dev="$dev" '$1 != "default" && $2 == "dev" && $3 != dev && $1 !~ /^fe80:/ { printf "%s ", $1 }')
if [ -z "$XRAY_NET" ]; then
  echo "caddy: no network beside edge, so no PROXY header is taken: the cover app sees Xray's address" >&2
  XRAY_NET=127.0.0.1/32
fi
export XRAY_NET
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
