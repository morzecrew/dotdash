#!/bin/sh
# Each device's subscription: its links from client-config, base64-encoded as
# the apps read them, in /sub/<token>, and its Xray config, the one --full
# prints, in /sub/<token>.json. The token is the first 32 hex
# characters of SHA-256("<subscription_key>:<uuid>"): different per device,
# and unguessable without the key. Caddy serves the files and holds none of
# the keys they are made from.
#
# It runs at start, so again whenever morzer restarts this service for a
# secret or parameter that changed: a device whose line was deleted loses its
# file, and a rotated key is in every file. With the subscription parameter
# off it leaves the directory empty. Then it marks the directory done for the
# healthcheck (.ready, which Caddy never serves: only 32-hex names), and waits.
#
# The files of a token no device has any more go first: a deleted device's,
# or every one after a rotated key. The rest stay served while they are
# written again, each to a new file renamed over the old, so a device's URL
# never answers 404 meanwhile, and a run stopped short, by a full volume or
# otherwise, leaves the last files served.
set -eu
out=/sub
# What a run stopped short left behind.
rm -f "$out/.ready" "$out/.full" "$out/.tokens" "$out/.keep" "$out/.routing.new" "$out"/*.new
if [ "${SUBSCRIPTION:-false}" = true ]; then
  key=$(cat /run/secrets/subscription_key)
  while read -r id _ || [ -n "${id:-}" ]; do
    case $id in '' | '#'*) continue ;; esac
    echo "$(printf '%s:%s' "$key" "$id" | sha256sum | cut -c1-32) $id"
  done </run/secrets/vless_clients >"$out/.tokens"
  # A decoy beside them, with no links, for cdn-check to fetch through each
  # CDN: named from the key, so no one else can ask for it, and holding the
  # rest of that hash, so cdn-check tells it from a site that answers any
  # path, as an app behind it (cover) may.
  decoy=$(printf '%s:cdn-check' "$key" | sha256sum)
  { cut -c1-32 "$out/.tokens"; echo "$decoy" | cut -c1-32; } >"$out/.keep"
  # shellcheck disable=SC2010 # the names are ours: 32 hex characters and a suffix
  ls "$out" | grep -vFf "$out/.keep" | while read -r f; do rm -f "$out/$f"; done
  n=0
  while read -r token id; do
    sh /task/client-config.sh --full "$id" >"$out/.full"
    grep -E '^(vless|hysteria2)://' "$out/.full" | base64 -w 0 >"$out/$token.new"
    # The same links for an app on Apple's network stack (Caddyfile: by its
    # User-Agent), whose own hello is Safari's: fp=safari, so the device's
    # TLS hello matches the platform its TCP comes from.
    grep -E '^(vless|hysteria2)://' "$out/.full" | sed 's/&fp=chrome&/\&fp=safari\&/g' | base64 -w 0 >"$out/$token.apple.new"
    # The config: the lines from its opening brace to its closing one, each
    # alone on its line, as client-config prints it.
    sed -n '/^{$/,/^}$/p' "$out/.full" >"$out/$token.json.new"
    mv "$out/$token.new" "$out/$token"
    mv "$out/$token.apple.new" "$out/$token.apple"
    mv "$out/$token.json.new" "$out/$token.json"
    n=$((n + 1))
  done <"$out/.tokens"
  echo "$decoy" | cut -c33-64 >"$out/decoy.new"
  mv "$out/decoy.new" "$out/$(echo "$decoy" | cut -c1-32)"
  rm -f "$out/.full" "$out/.tokens" "$out/.keep"
  # happ_routing: Happ's routing profile, base64-encoded for its routing
  # header, which Caddy sends with every subscription while this file is
  # there (a dotfile, never served itself). Its lines are joined: JSON keeps
  # no meaning in them.
  case $(printf '%s' "${HAPP_ROUTING:-none}" | tr -d '\r\n') in
  none | '') rm -f "$out/.routing" ;;
  '{'*'}')
    printf '%s' "$HAPP_ROUTING" | tr -d '\r\n' | base64 -w 0 >"$out/.routing.new"
    mv "$out/.routing.new" "$out/.routing" ;;
  *) echo "happ_routing is not a JSON object: no routing profile sent" >&2; rm -f "$out/.routing" ;;
  esac
  echo "subscription: ${n} device(s)"
else
  find "$out" -mindepth 1 -delete
  echo "subscription: off"
fi
: >"$out/.ready"
exec sleep 2147483647
