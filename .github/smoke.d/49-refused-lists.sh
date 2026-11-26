#!/usr/bin/env bash
# A relays or cdn_extra line, or a field of one, that client-config would
# leave out fails the change that brings it (the lists health check), with its
# line and reason, and morzer rolls it back: the lines before it stay, and
# devices keep their links. One case each: a relays line with a malformed
# field, an extra Xray refuses. What costs devices nothing only warns and
# applies: a field this release doesn't know (a newer relay's line may carry
# one), a name two relays share, a pool member that names nothing.
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
links() { sudo morzer task run client-config --output -- --full | grep -cE '^vless://[^@]*@198\.51\.100\.[78]:443\?.*&security=reality&' || true; }
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
refused cdn_extra "cdn_extra: line 1: Xray refuses the extra for cdn.test" 'cdn.test {"mode": broken}'

# Warnings alone apply, and the relays carry on.
printf '%s\n' "${good} name=twin future=1" \
  "198.51.100.8 site-c.test pbkC000000000000000000000000000000000000000 0123456789abcdef mlkem768x25519plus.native.0rtt.c name=twin" |
  sudo morzer config set --set-file relays=- >/dev/null || die "a field this release doesn't know, or a taken name, failed the apply"
printf '%s\n' "a 198.51.100.7 nothing.test" | sudo morzer config set --set-file pools=- >/dev/null ||
  die "a pool member that names nothing failed the apply"
[ "$(links)" = "$((2 * before))" ] || die "with only warnings, the relays do not each give their links"
echo "${0##*/}: an unknown field, a taken name and a pool member naming nothing only warn, and apply"
