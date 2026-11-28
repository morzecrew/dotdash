#!/bin/sh
# Prints each server group's state as the gateway's agent last found it, a
# line each, as the image's gateway-status prints it, and what to look at for
# a group that is not live:
#
#   a                live     a1.example.com ok 41 ms, a2.example.com down (503 Service Unavailable); 14 devices, digest 3f9a1c2b, list 42 s old
#   b                refused  b.example.com refused (no list for this relay (404))
#   gateway: last round 12 s ago
#
# live: one of its servers serves this relay its device list, so its devices
# get through; down: none answers, and its devices get nothing, kept from the
# last list; refused: a server answers that it has no list for this relay,
# which drops its devices; starting: no round yet. Exits 1 while the agent's
# last round that reached Xray's API is over two minutes old, as the health
# check does.
set -u
out=$(/opt/xray/xray-entrypoint gateway-status 2>&1)
status=$?
printf '%s\n' "$out"
printf '%s\n' "$out" | awk '
  $2 == "refused" { printf "%s: its servers answer, but have no list for this relay: is this relay'\''s relay/1 line in %s'\''s relays, and is its servers line here the one relay-config prints there now?\n", $1, $1 }
  $2 == "down" { printf "%s: no server serves its list: are they up, does this machine reach them, and do they let this relay in (its relay/1 line in %s'\''s relays, its servers line here current)?\n", $1, $1 }
  /^no group yet/ { print "add each server group'\''s server/1 line, as its relay-config -- <this relay'\''s name> prints it: sudo EDITOR=nano morzer secret edit servers" }'
exit "$status"
