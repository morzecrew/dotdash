#!/bin/sh
# Each device's subscription: its links from client-config, base64-encoded as
# the apps read them, in /sub/<token>. The token is the first 32 hex
# characters of SHA-256("<subscription_key>:<uuid>"): different per device,
# and unguessable without the key. Caddy serves the files and holds none of
# the keys they are made from.
#
# It runs at start, so again whenever morzer restarts this service for a
# secret or parameter that changed: a device whose line was deleted loses its
# file, and a rotated key is in every file. With the subscription parameter
# off it leaves the directory empty. Then it marks the directory done for the
# healthcheck (.ready, which Caddy never serves: only 32-hex names), and waits.
set -eu
out=/sub
find "$out" -mindepth 1 -delete
if [ "${SUBSCRIPTION:-false}" = true ]; then
  key=$(cat /run/secrets/subscription_key)
  n=0
  while read -r id _ || [ -n "${id:-}" ]; do
    case $id in '' | '#'*) continue ;; esac
    token=$(printf '%s:%s' "$key" "$id" | sha256sum | cut -c1-32)
    sh /task/client-config.sh --full "$id" | grep '^vless://' | base64 -w 0 >"$out/$token.new"
    mv "$out/$token.new" "$out/$token"
    n=$((n + 1))
  done </run/secrets/vless_clients
  echo "subscription: ${n} device(s)"
else
  echo "subscription: off"
fi
: >"$out/.ready"
exec sleep 2147483647
