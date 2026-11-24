#!/bin/sh
# Prints the OpenFlux link of each device the openflux profile runs a channel
# for, or of the one named after --, as "<device> <link>". The OpenFlux app
# takes the link pasted, or scanned from a QR code made of it. A link holds
# its channel's key: whoever has it takes the device's place.
#
#   openflux-link.sh [device]
#
# The exits make the links, and keep them with the rest of each device's
# state (openflux/openflux.sh); this reads them, on no network.
set -u
want=${1:-}
found=''
for dir in /var/lib/openflux/*/; do
  # on: the exits' last start ran a channel for it.
  [ -e "$dir/on" ] && [ -s "$dir/link" ] && [ -s "$dir/name" ] || continue
  name=$(cat "$dir/name")
  [ -z "$want" ] || [ "$want" = "$name" ] || continue
  printf '%s %s\n' "$name" "$(cat "$dir/link")"
  found=1
done
[ -n "$found" ] && exit 0
if [ -n "$want" ]; then
  echo "no OpenFlux channel for '$want': it needs a line in openflux_channels, a device in vless_clients, and the openflux profile on" >&2
else
  echo "no OpenFlux channel: the openflux profile is off, or openflux_channels names no device in vless_clients" >&2
fi
exit 1
