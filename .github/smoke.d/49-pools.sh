#!/usr/bin/env bash
# Pools (the pools parameter). With two devices added, pooled in pool a and
# unpooled in none, three relays and three CDN hosts, pool a holding a relay
# and a CDN host and pool b another of each:
# - pooled gets pool a's relay and CDN host and those in no pool, as links
#   and as outbounds, and nothing of pool b's;
# - unpooled gets every relay and CDN host;
# - a member that names nothing is reported;
# - with pools unset, pooled gets everything again.
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qx '  pools:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates pools"
  exit 0
fi

secrets=/run/dotdash/secrets
before=$(sudo cat "${secrets}/vless_clients")
restore() {
  sudo morzer config unset pools >/dev/null 2>&1 || true
  sudo morzer config unset relays >/dev/null 2>&1 || true
  sudo morzer config set cdn_hosts=none >/dev/null 2>&1 || true
  printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null 2>&1 || true
}
trap restore EXIT

# Captured, then read: a reader that stops early would kill the task's output.
config() { sudo morzer task run client-config --output -- --full "$1"; }
hosts() { # <client-config output>: the relays and CDN hosts its links go through
  sed -nE 's/^vless:\/\/.*#.*%5B(relay|cdn)%20([^%]+).*/\2/p' <<<"$1" | sort -u | tr '\n' ' '
}
tags() { # <client-config output>: its config's relay and CDN outbounds
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"$1" |
    jq -r '.outbounds[].tag' | grep -E '^dotdash-(relay|cdn)-' | sort | tr '\n' ' ' || true
}

printf '%s\n%s pooled\n%s unpooled\n' "${before}" \
  "$(cat /proc/sys/kernel/random/uuid)" "$(cat /proc/sys/kernel/random/uuid)" |
  sudo morzer secret set vless_clients >/dev/null || die "could not add two devices"
printf '%s\n' \
  "relay-a.test site-a.test pbkA 0011223344556677 mlkem.a" \
  "relay-b.test site-b.test pbkB 8899aabbccddeeff mlkem.b own-site" \
  "relay-s.test site-s.test pbkS 0123456789abcdef mlkem.s" |
  sudo morzer config set --set-file relays=- >/dev/null || die "could not set relays"
sudo morzer config set cdn_hosts=cdn-a.test,cdn-b.test,cdn-s.test >/dev/null || die "could not set cdn_hosts"
printf '%s\n' "a pooled relay-a.test cdn-a.test" "b relay-b.test cdn-b.test nothing.test" |
  sudo morzer config set --set-file pools=- >/dev/null || die "could not set pools"

text=$(config pooled)
[ "$(hosts "${text}")" = "cdn-a.test cdn-s.test relay-a.test relay-s.test " ] ||
  die "the device in pool a gets other relays or CDN hosts than pool a's and those in no pool: $(hosts "${text}")"
[ "$(tags "${text}")" = "dotdash-cdn-1 dotdash-cdn-2 dotdash-relay-1 dotdash-relay-2 " ] ||
  die "the device in pool a has other relay or CDN outbounds than its links: $(tags "${text}")"
echo "${0##*/}: a device in a pool gets its pool's relays and CDN hosts and those in none"

text=$(config unpooled)
[ "$(hosts "${text}")" = "cdn-a.test cdn-b.test cdn-s.test relay-a.test relay-b.test relay-s.test " ] ||
  die "the device in no pool does not get every relay and CDN host: $(hosts "${text}")"
echo "${0##*/}: a device in no pool gets every relay and CDN host"

err=$(config pooled 2>&1 >/dev/null)
grep -qF 'pools: nothing.test is no device name, relay host or CDN host' <<<"${err}" ||
  die "a pool member that names nothing is not reported"
echo "${0##*/}: a pool member that names nothing is reported"

sudo morzer config unset pools >/dev/null || die "could not unset pools"
text=$(config pooled)
[ "$(hosts "${text}")" = "cdn-a.test cdn-b.test cdn-s.test relay-a.test relay-b.test relay-s.test " ] ||
  die "with pools unset, the device once in pool a does not get every relay and CDN host"
echo "${0##*/}: with pools unset, every device gets everything"
