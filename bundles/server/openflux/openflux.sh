#!/bin/sh
# The openflux profile's container: one OpenFlux exit for each line of
# openflux_channels whose device is in vless_clients, each on a channel of its
# own, because an exit serves one client at a time. Every connection an exit
# opens goes through Xray's openflux hop, so it takes the routing devices'
# connections take, the blocks included, and leaves through the upstreams;
# UDP goes the same way, or nowhere where upstream_udp is off. Only the
# carriers' own connections leave this container directly.
#
#   <device> <kind>[=<link>] [<kind>[=<link>] ...]
#
# A device is a vless_clients name or UUID. A kind is a short alias of an
# OpenFlux transport type (kind below), or the type itself. co makes its own
# rooms when given no link, once, and tm its own call where call_provider is
# tm and the call_token secret is set. direct takes the address it listens
# on, for tests. Each device's state is kept under its UUID in
# /var/lib/openflux: the key, made once, the rooms, the call, the cookie jars,
# and the link the openflux-link task prints. A device deleted from
# vless_clients loses its state at the next start, so adding it again, with a
# new UUID, gives it a new key, rooms and call; one left out of
# openflux_channels keeps them.
#
# Any exit stopping stops the container, which the restart policy brings
# back with every channel.
set -eu
umask 077
STATE=${OPENFLUX_STATE:-/var/lib/openflux}
CLIENTS=${OPENFLUX_CLIENTS:-/run/secrets/vless_clients}
PROVIDER=${OPENFLUX_CALL_PROVIDER:-none}
TOKEN=${OPENFLUX_CALL_TOKEN:-/run/secrets/call_token}
UPSTREAM=${OPENFLUX_UPSTREAM:-xray:1082}
say() { echo "openflux: $*"; }

# kind <alias>: the OpenFlux transport type an alias names, or a type itself;
# status 1 for anything else, which OpenFlux would refuse at start, taking
# every channel down with it.
kind() {
  case $1 in
  tm) echo telemost ;; co) echo cupsonline ;;
  telemost | cupsonline | direct) echo "$1" ;;
  *) return 1 ;;
  esac
}

# uuid_of <device>: the device's UUID from vless_clients, by name or UUID.
uuid_of() {
  awk -v d="$1" '$1 !~ /^#/ && NF && ($1 == d || $2 == d) { print $1; exit }' "$CLIENTS"
}

# rooms <dir> <type>: the rooms a co channel made, made once.
rooms() {
  [ -s "$1/$2.rooms" ] || {
    printf '{"id":1,"method":"createRooms","params":{}}\n' |
      timeout 120 openflux --node-wizard 2>/dev/null |
      sed -n 's/.*"rooms":"\([^"]*\)".*/\1/p' | sed -n 1p >"$1/$2.rooms.new" || true
    [ -s "$1/$2.rooms.new" ] || { rm -f "$1/$2.rooms.new"; return 1; }
    mv "$1/$2.rooms.new" "$1/$2.rooms"
  }
  cat "$1/$2.rooms"
}

# call <dir>: the call a tm channel made through call_provider's API with the
# call_token secret, made once; status 2 when they aren't set. Its waiting
# room is open: the exit and the app join with the link alone. The provider
# deletes calls only for business accounts, so a deleted device's call stays
# behind, unused. busybox wget takes a header on its command line alone, so
# the token is in this container's process list for the second it takes.
call() {
  [ -s "$1/call" ] || {
    [ "$PROVIDER" = tm ] && [ -s "$TOKEN" ] || return 2
    wget -q -O - -T 20 --header "Authorization: OAuth $(tr -d ' \n' <"$TOKEN")" \
      --header 'Content-Type: application/json' --post-data '{"waiting_room_level":"PUBLIC"}' \
      https://cloud-api.yandex.net/v1/telemost-api/conferences 2>/dev/null |
      sed -n 's/.*"join_url":"\([^"]*\)".*/\1/p' >"$1/call.new" || true
    [ -s "$1/call.new" ] || { rm -f "$1/call.new"; return 1; }
    mv "$1/call.new" "$1/call"
  }
  cat "$1/call"
}

# channel <device> <uuid> <kind...>: writes the exit's config and the
# device's link into its state, or fails with nothing to run.
channel() {
  device=$1 dir=$STATE/$2
  shift 2
  mkdir -p "$dir"
  [ -s "$dir/key" ] || head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$dir/key"
  printf '[Interface]\nRole = exit\nMode = l4\nEncryptionKeyFile = %s/key\nCookieStore = %s/cookies.json\n' \
    "$dir" "$dir" >"$dir/node.conf"
  json='' n=0
  for t in "$@"; do
    short=${t%%=*} value=
    case $t in *=*) value=${t#*=} ;; esac
    case $t in *[\"\\]*) say "$device: '$t' holds a quote or a backslash, skipped"; continue ;; esac
    type=$(kind "$short") || { say "$device: '$short' is no kind of carrier, skipped"; continue; }
    if [ -z "$value" ]; then
      case $type in
      cupsonline)
        value=$(rooms "$dir" "$type") || { say "$device: $short rooms could not be made, skipped until the next start"; continue; } ;;
      telemost)
        rc=0
        value=$(call "$dir") || rc=$?
        case $rc in
        0) ;;
        2) say "$device: $short needs its link, as $short=<link>, or call_provider=tm and the call_token secret, skipped"; continue ;;
        *) say "$device: $short: call_provider's API made no call, skipped until the next start"; continue ;;
        esac ;;
      *) say "$device: $short needs its link, as $short=<link>, skipped"; continue ;;
      esac
    fi
    n=$((n + 1))
    if [ "$type" = direct ]; then
      printf '\n[Transport %s-%s]\nType = direct\nPriority = 50\nListen = %s\n' "$short" "$n" "$value" >>"$dir/node.conf"
      json="$json,{\"type\":\"direct\",\"dial\":\"$value\"}"
    else
      printf '\n[Transport %s-%s]\nType = %s\nPriority = 50\nURL = %s\n' "$short" "$n" "$type" "$value" >>"$dir/node.conf"
      json="$json,{\"type\":\"$type\",\"url\":\"$value\"}"
    fi
  done
  [ "$n" -gt 0 ] || { say "$device: no transport to run, no channel"; return 1; }
  printf '{"name":"%s","negotiate":true,"secret":"%s","transports":[%s]}' "$device" "$(cat "$dir/key")" "${json#,}" |
    openflux --make-link - | sed -n 's/.*"link":"\([^"]*\)".*/\1/p' >"$dir/link"
  [ -s "$dir/link" ] || { say "$device: no link could be made, no channel"; return 1; }
  printf '%s\n' "$device" >"$dir/name"
  : >"$dir/on"
}

pids='' keep=''
stop() {
  # shellcheck disable=SC2086 # one PID a word
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
  exit "$1"
}
trap 'stop 0' TERM INT

# Which devices have a channel is this start's to say (the openflux-link task).
rm -f "$STATE"/*/on

while read -r device transports; do
  case $device in '' | '#'*) continue ;; *[\"\\]*) say "a device name with a quote or a backslash, skipped"; continue ;; esac
  uuid=$(uuid_of "$device")
  [ -n "$uuid" ] || { say "$device: no such device in vless_clients, no channel"; continue; }
  case " $keep " in *" $uuid "*) say "$device: a second line for one device, skipped"; continue ;; esac
  # shellcheck disable=SC2086 # one transport a word
  channel "$device" "$uuid" $transports || continue
  keep="$keep $uuid"
  # Each line of an exit's log names its device.
  (openflux --config "$STATE/$uuid/node.conf" --upstream-proxy="$UPSTREAM" 2>&1; echo "stopped ($?)") |
    while IFS= read -r line; do printf '%s: %s\n' "$device" "$line"; done &
  pids="$pids $!"
  say "$device: on $(grep -c '^\[Transport' "$STATE/$uuid/node.conf") transport(s)"
done <<EOF
${OPENFLUX_CHANNELS:-}
EOF

# A device deleted from vless_clients loses its key and rooms. One merely
# left out of openflux_channels keeps them, and its link, for its return.
for dir in "$STATE"/*/; do
  [ -d "$dir" ] || continue
  uuid=$(basename "$dir")
  [ -n "$(uuid_of "$uuid")" ] || { rm -rf "$dir" && say "$uuid, deleted from vless_clients: its state removed"; }
done

[ -n "$pids" ] || say "no channel to run: idle"
while :; do
  for pid in $pids; do
    kill -0 "$pid" 2>/dev/null || { say "a channel stopped; every channel restarts with the container"; stop 1; }
  done
  sleep 5 &
  wait $! || true
done
