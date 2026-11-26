#!/usr/bin/env bash
# A relays, pools or cdn_extra line client-config would leave out or cut down
# fails the change that brings it (the lists health check), with its line and
# reason, and morzer rolls it back: the lines before it stay, and devices keep
# their links. One case each: a relays line with a malformed field, a pool
# member that names nothing, an extra Xray refuses.
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

restore() {
  sudo morzer config unset relays >/dev/null 2>&1 || true
  sudo morzer config unset pools >/dev/null 2>&1 || true
  printf 'none\n' | sudo morzer config set --set-file cdn_extra=- >/dev/null 2>&1 || true
}
trap restore EXIT

good="198.51.100.7 site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b"
printf '%s\n' "${good}" | sudo morzer config set --set-file relays=- >/dev/null || die "could not set a good relays line"
links() { sudo morzer task run client-config --output -- --full | grep -c '^vless://.*#relay%20%C2%B7%20reality$' || true; }
before=$(links)
[ "${before}" -gt 0 ] || die "no REALITY link through the good relay"

refused() { # <parameter> <reason> <value>: setting it fails, saying the reason, and the good relay's links stay
  local err
  if err=$(printf '%s\n' "$3" | sudo morzer config set --set-file "$1=-" 2>&1 >/dev/null); then
    die "$1: a bad line was applied"
  fi
  grep -qF "$2" <<<"${err}" || die "$1: refused, but without the reason ($2): $(tail -n 3 <<<"${err}")"
  [ "$(links)" = "${before}" ] || die "$1: after the refusal, the good relay's links are not as before"
  echo "${0##*/}: $1: a bad line is refused at apply, saying \"$2\", and rolled back"
}

refused relays "relays: line 2: the cdn= field of 198.51.100.8" "${good}
198.51.100.8 site-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c cdn=bad_name!"
refused pools "pools: line 1: nothing.test is no device name" "a 198.51.100.7 nothing.test"
refused cdn_extra "cdn_extra: line 1: Xray refuses the extra for cdn.test" 'cdn.test {"mode": broken}'
