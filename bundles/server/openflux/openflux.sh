#!/bin/sh
# The openflux profile's container: one OpenFlux exit for each line of
# openflux_channels whose device is in vless_clients, each on a channel of its
# own, because an exit serves one client at a time. Every connection an exit
# opens goes through the gate's egress hop, which takes it out through the
# upstreams; UDP goes the same way, or nowhere where upstream_udp is off.
# Only the carriers' own connections leave this container directly.
#
#   <device> <type>[=<link>] [<type>[=<link>] ...]
#
# A device is a vless_clients name or UUID. A type is an OpenFlux transport.
# cupsonline and avito make their own rooms when given no link, once; the
# others take the link the owner made with an account. direct takes the
# address it listens on, for tests. Each device's state is kept under its
# UUID in /var/lib/openflux: the key, made once, the rooms, the cookie jars,
# and the link the openflux-link task prints. A device deleted from
# vless_clients loses its state at the next start, so adding it again, with a
# new UUID, gives it a new key and new rooms; one left out of
# openflux_channels keeps them.
#
# Any exit stopping stops the container, which the restart policy brings
# back with every channel.
set -eu
umask 077
STATE=${OPENFLUX_STATE:-/var/lib/openflux}
CLIENTS=${OPENFLUX_CLIENTS:-/run/secrets/vless_clients}
UPSTREAM=${OPENFLUX_UPSTREAM:-gate:1080}
say() { echo "openflux: $*"; }

# uuid_of <device>: the device's UUID from vless_clients, by name or UUID.
uuid_of() {
  awk -v d="$1" '$1 !~ /^#/ && NF && ($1 == d || $2 == d) { print $1; exit }' "$CLIENTS"
}

# rooms <dir> <type>: the rooms a cupsonline or avito channel made, made once.
rooms() {
  [ -s "$1/$2.rooms" ] || {
    case $2 in cupsonline) m=createRooms ;; avito) m=createAvitoRooms ;; esac
    printf '{"id":1,"method":"%s","params":{}}\n' "$m" |
      timeout 120 openflux --node-wizard 2>/dev/null |
      sed -n 's/.*"rooms":"\([^"]*\)".*/\1/p' | sed -n 1p >"$1/$2.rooms.new" || true
    [ -s "$1/$2.rooms.new" ] || { rm -f "$1/$2.rooms.new"; return 1; }
    mv "$1/$2.rooms.new" "$1/$2.rooms"
  }
  cat "$1/$2.rooms"
}

# channel <device> <uuid> <transport...>: writes the exit's config and the
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
    type=${t%%=*} value=
    case $t in *=*) value=${t#*=} ;; esac
    case $t in *[\"\\]*) say "$device: '$t' holds a quote or a backslash, skipped"; continue ;; esac
    if [ -z "$value" ]; then
      case $type in
      cupsonline | avito)
        value=$(rooms "$dir" "$type") || { say "$device: $type rooms could not be made, skipped until the next start"; continue; } ;;
      *) say "$device: $type needs its link, as $type=<link>, skipped"; continue ;;
      esac
    fi
    n=$((n + 1))
    if [ "$type" = direct ]; then
      printf '\n[Transport %s-%s]\nType = direct\nPriority = 50\nListen = %s\n' "$type" "$n" "$value" >>"$dir/node.conf"
      json="$json,{\"type\":\"direct\",\"dial\":\"$value\"}"
    else
      printf '\n[Transport %s-%s]\nType = %s\nPriority = 50\nURL = %s\n' "$type" "$n" "$type" "$value" >>"$dir/node.conf"
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
