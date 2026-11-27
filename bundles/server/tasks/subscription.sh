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
# It also writes each relay's device list, whether or not subscriptions are
# on (below), into .lists, which only Caddy's internal listener serves.
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
  # The relays' lists stay, written again below: one gone even for a moment
  # answers 404, which tells a relay these servers no longer list it.
  find "$out" -mindepth 1 ! -path "$out/.lists" ! -path "$out/.lists/*" -delete
  echo "subscription: off"
fi

# Each relay/1 line's device list (relays), which the relay fetches every
# minute through its tunnel from list.sub.dotdash.internal/<list token>, and
# Xray hands to Caddy's internal listener for relays' users alone
# (xray.json.tmpl, caddy/Caddyfile). The list token is the first 32 hex
# characters of sha256("<relay id>:list"), the id the image derives for the
# relay from relay_seed (relay-id). A list holds every device, with the first
# 12 hex characters of its subscription token while subscriptions are on, by
# which the relay routes the device's subscription here, and the other relays,
# for one that goes through this relay:
#
#   # dotdash relay list v1
#   <id> [<name> [<first 12 hex of its subscription token>]]
#   <id> relay-<another relay's name>
#
# A device with no name is named by the first 8 hex of its id's sha256 where
# a prefix follows, which needs a name before it. Kinds stay off: the relay
# makes no links. In a dotdir, which the public site never serves.
lists=$out/.lists
mkdir -p "$lists"
rm -f "$lists"/*.new
relays=$(printf '%s\n' "${RELAYS:-}" | awk '$1 == "relay/1" && NF >= 8 { print $2, $3 }' | while read -r name nonce; do
  # The lists health check names a malformed line; Xray refuses it too.
  id=$(/opt/xray/xray-entrypoint relay-id /run/secrets/relay_seed "$name" "$nonce" 2>/dev/null) ||
    { echo "subscription: no list for the relay/1 line of $name, whose name or nonce is malformed" >&2; continue; }
  echo "$id $name $(printf '%s:list' "$id" | sha256sum | cut -c1-32)"
done)
key=
[ "${SUBSCRIPTION:-false}" != true ] || key=$(cat /run/secrets/subscription_key)
devices=$(while read -r id name _ || [ -n "${id:-}" ]; do
  case $id in '' | '#'*) continue ;; esac
  if [ -z "$key" ]; then echo "$id${name:+ $name}"; continue; fi
  [ -n "${name:-}" ] || name=$(printf '%s' "$id" | sha256sum | cut -c1-8)
  echo "$id $name $(printf '%s:%s' "$key" "$id" | sha256sum | cut -c1-12)"
done </run/secrets/vless_clients)
printf '%s\n' "$relays" | while read -r rid _ token; do
  [ -n "$rid" ] || continue
  { echo '# dotdash relay list v1'
    printf '%s\n' "$devices" | sed '/^$/d'
    printf '%s\n' "$relays" | awk -v me="$rid" 'NF && $1 != me { print $1, "relay-" $2 }'
  } >"$lists/$token.new"
  mv "$lists/$token.new" "$lists/$token"
done
# The lists of relays no longer in relays go: their relays drop these
# servers' devices at their next fetch.
for f in "$lists"/*; do
  [ -e "$f" ] || continue
  printf '%s\n' "$relays" | awk -v t="${f##*/}" '$3 == t { k = 1 } END { exit !k }' || rm -f "$f"
done
echo "subscription: $(printf '%s\n' "$relays" | grep -c .) relay list(s)"
: >"$out/.ready"
exec sleep 2147483647
