#!/usr/bin/env bash
# What the upstream learns. With resolve=upstream it is handed hostnames; with
# resolve=gateway it must be handed addresses only, the DNS itself going out
# through it as DoH, and a public name that points at a private address must
# not get out at all. The rig's upstream logs every destination it is asked
# for (pre-apply/10-rig.sh). Needs the internet: DoH and a public site.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before the parameter has nothing to check.
if ! sudo morzer config list 2>/dev/null | grep -qw resolve; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

log=/rig/upstream-log/access.log
since() { tail -n "+$(($1 + 1))" "${log}"; }
lines() { wc -l <"${log}"; }
fetch() { # <url>: through 10-clients.sh's REALITY client
  curl -sS -o /dev/null --max-time 20 --retry 3 --retry-delay 2 --retry-all-errors \
    -w '%{http_code}' --socks5-hostname 127.0.0.1:11080 "$1"
}

restore() { sudo morzer config set resolve=gateway healthcheck_url=http://11.99.0.10:8000/ >/dev/null; }

# The control: with resolve=upstream the upstream is handed the name `target`,
# which only it resolves, and its log shows it.
sudo morzer config set resolve=upstream >/dev/null || die "could not switch to resolve=upstream"
mark=$(lines)
code=$(fetch http://target:8000/) || true
seen=$(since "${mark}")
if [ "${code}" != 200 ]; then restore; die "no answer from the target by name with resolve=upstream"; fi
if ! grep -qF 'target:8000' <<<"${seen}"; then
  restore
  die "the upstream's log does not show the names it is handed, so the checks below would prove nothing"
fi
echo "35-resolve.sh: resolve=upstream hands the upstream the name, and its log shows it"

mark=$(lines)
sudo morzer config set resolve=gateway healthcheck_url=https://www.gstatic.com/generate_204 >/dev/null \
  || { restore; die "could not switch to resolve=gateway"; }

code=$(fetch https://www.gstatic.com/generate_204) || true
seen=$(since "${mark}")
if [ "${code}" != 204 ]; then restore; die "no answer from a public site with resolve=gateway (${code})"; fi
if grep -qF 'gstatic' <<<"${seen}"; then restore; die "the upstream was handed a hostname with resolve=gateway"; fi
if ! grep -qE 'accepted //[0-9]+(\.[0-9]+){3}:443' <<<"${seen}"; then restore; die "the upstream's log shows no address for the public site"; fi
if ! grep -qF '1.1.1.1:443' <<<"${seen}"; then restore; die "the DoH did not go out through the upstream"; fi
echo "35-resolve.sh: resolve=gateway hands the upstream addresses only, and its DoH goes through it"

# localtest.me resolves to 127.0.0.1 for everyone: resolved here first, it
# meets the private-address block and never reaches the upstream.
mark=$(lines)
code=$(fetch http://localtest.me:8000/) || true
seen=$(since "${mark}")
if [ "${code}" = 200 ] || grep -qE 'localtest|127\.0\.0\.1' <<<"${seen}"; then
  restore
  die "a public name pointing at a private address got out with resolve=gateway"
fi
echo "35-resolve.sh: a public name pointing at a private address is blocked"
restore
