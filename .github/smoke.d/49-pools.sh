#!/usr/bin/env bash
# Pools (the pools parameter). With two devices added, pooled in pool a and
# unpooled in none, three relays and three CDN hosts, pool a holding a relay
# and a CDN host and pool b another of each:
# - pooled gets pool a's relay and CDN host and those in no pool, as links
#   and as outbounds, and nothing of pool b's;
# - unpooled gets every relay and CDN host;
# - with pools unset, pooled gets everything again.
# (A member that names nothing is refused at apply: 49-refused-lists.sh.)
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

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
hosts() { # <client-config output>: the relays and CDN hosts its links go through, by the addresses of those named "relay <n> · <transport>" or "server · cdn <n>"
  sed -nE 's/^vless:\/\/[^@]+@([^:]+):.*#(relay%20[0-9]+%20%C2%B7%20[a-z0-9%]+|server%20%C2%B7%20cdn%20[0-9]+)$/\1/p' <<<"$1" | sort -u | tr '\n' ' '
}
tags() { # <client-config output>: its config's relay and CDN outbounds
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"$1" |
    jq -r '.outbounds[].tag' | grep -E '^dotdash-(relay|cdn)-' | sort | tr '\n' ' ' || true
}

printf '%s\n%s pooled\n%s unpooled\n' "${before}" \
  "$(cat /proc/sys/kernel/random/uuid)" "$(cat /proc/sys/kernel/random/uuid)" |
  sudo morzer secret set vless_clients >/dev/null || die "could not add two devices"
printf '%s\n' \
  "relay-a.test site-a.test pbkA000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.a" \
  "relay-b.test site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b own-site" \
  "relay-s.test site-s.test pbkS000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.s" |
  sudo morzer config set --set-file relays=- >/dev/null || die "could not set relays"
sudo morzer config set cdn_hosts=cdn-a.test,cdn-b.test,cdn-s.test >/dev/null || die "could not set cdn_hosts"
printf '%s\n' "a pooled relay-a.test cdn-a.test" "b relay-b.test cdn-b.test" |
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

sudo morzer config unset pools >/dev/null || die "could not unset pools"
text=$(config pooled)
[ "$(hosts "${text}")" = "cdn-a.test cdn-b.test cdn-s.test relay-a.test relay-b.test relay-s.test " ] ||
  die "with pools unset, the device once in pool a does not get every relay and CDN host"
echo "${0##*/}: with pools unset, every device gets everything"

# A relay's own CDNs (cdn= on its line) are pool members too: with the relay in
# no pool, pool a holding one of its CDNs and pool b another, pooled gets pool
# a's and the one in no pool, unpooled all three, and neither is reported.
printf '%s\n' "relay-c.test site-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c own-site 00112233445566778899aabbccddeeff cdn=cdn-r1.test,cdn-r2.test,cdn-r3.test" |
  sudo morzer config set --set-file relays=- >/dev/null || die "could not set relays"
printf '%s\n' "a pooled cdn-r1.test" "b cdn-r2.test" |
  sudo morzer config set --set-file pools=- >/dev/null || die "could not set pools"
rcdns() { sed -nE 's/^vless:\/\/[^@]+@([^:]+):.*#relay%20%C2%B7%20cdn%20[0-9]+$/\1/p' <<<"$1" | sort -u | tr '\n' ' '; }
[ "$(rcdns "$(config pooled)")" = "cdn-r1.test cdn-r3.test " ] ||
  die "the device in pool a gets other CDNs of the relay than pool a's and the one in no pool: $(rcdns "$(config pooled)")"
[ "$(rcdns "$(config unpooled)")" = "cdn-r1.test cdn-r2.test cdn-r3.test " ] ||
  die "the device in no pool does not get every CDN of the relay"
! grep -q 'cdn-r[12]\.test is no device name' <<<"$(config pooled 2>&1 >/dev/null)" ||
  die "a relay's CDN in a pool is reported as naming nothing"
echo "${0##*/}: a relay's own CDNs are pooled like any CDN host"
