#!/usr/bin/env bash
# What the relay tells an authority it follows (manifest `published`): the
# facts task's JSON is relay-entry's line, at entry_host, which relay-entry
# also takes when given no address; without either, both say what to set.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  facts:$' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

restore() { sudo morzer config unset entry_host >/dev/null; }
if out=$(sudo morzer task run facts --output 2>&1); then die "facts ran with no entry_host and no own-site: ${out}"; fi
grep -q 'set entry_host' <<<"${out}" || die "facts without entry_host did not say to set it: ${out}"

sudo morzer config set entry_host=127.0.0.1 >/dev/null || die "could not set entry_host"
facts=$(sudo morzer task run facts --output) || { restore; die "the facts task failed"; }
entry=$(sudo morzer task run relay-entry --output | grep -m1 '^127\.0\.0\.1 ' || true)
restore
[ -n "${entry}" ] || die "relay-entry with entry_host and no argument printed no line for 127.0.0.1"
read -r host site pbk sid enc _ <<<"${entry}"
want=$(jq -nc --arg h "${host}" --arg s "${site}" --arg p "${pbk}" --arg i "${sid}" --arg e "${enc}" \
  '{entry_host: $h, site: $s, public_key: $p, short_id: $i, encryption: $e}')
got=$(jq -c '{entry_host, site, public_key, short_id, encryption}' <<<"${facts}") || die "the facts are not JSON: ${facts}"
[ "${got}" = "${want}" ] || die "the facts are not relay-entry's line: ${got} against ${want}"
echo "${0##*/}: facts are relay-entry's line at entry_host, and relay-entry takes entry_host too"
