#!/usr/bin/env bash
# exit-check reports what leaves through the upstream, asking the rig's stand-
# ins (pre-apply/10-rig.sh's target) rather than the internet: an IPv4 exit
# with its network, IPv6 unavailable where the upstream cannot reach it, and a
# mismatch where both answer from different networks.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before the exit-check task has nothing to check.
if ! sudo grep -qF '  exit-check:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

exit_check() { sudo morzer task run exit-check --output -- "$@" 2>&1; }
expect() { # <output> <line pattern> <what>
  grep -qE "$2" <<<"$1" || die "exit-check: $3: $1"
}

out=$(exit_check http://11.99.0.10:8000/ip4 http://ip6.invalid/ http://11.99.0.10:8000/info) \
  || die "exit-check failed with an IPv4 exit: ${out}"
expect "${out}" '^IPv4 exit  203\.0\.113\.7  AS64500 Rig Network  ZZ$' "no IPv4 exit with its network"
expect "${out}" '^IPv6 exit  unavailable: ' "IPv6 not reported unavailable"
expect "${out}" '^IPv6 is unavailable at the upstream' "no verdict for IPv4 only"
echo "30-exit-check.sh: IPv4 exit, IPv6 unavailable"

out=$(exit_check http://11.99.0.10:8000/ip4 http://11.99.0.10:8000/ip6 http://11.99.0.10:8000/info) \
  || die "exit-check failed with both exits: ${out}"
expect "${out}" '^IPv6 exit  2001:db8::7  AS64501 Other Network  YY$' "no IPv6 exit with its network"
expect "${out}" '^MISMATCH: IPv4 leaves from AS64500' "no mismatch reported for different networks"
echo "30-exit-check.sh: exits in different networks reported as a mismatch"
