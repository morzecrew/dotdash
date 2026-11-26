#!/usr/bin/env bash
# What the relay tells an authority it follows (manifest `published`): the
# facts task's JSON is relay-entry's line, at entry_host, which relay-entry
# also takes when given no address; without either, both say what to set.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

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

# The name parameter: relay-entry ends the line with name=, the facts carry it,
# and a malformed one is left out of both.
unname() { sudo morzer config unset entry_host name >/dev/null; }
sudo morzer config set entry_host=127.0.0.1 name=edge-1 >/dev/null || die "could not set entry_host and name"
entry=$(sudo morzer task run relay-entry --output | grep -m1 '^127\.0\.0\.1 ' || true)
facts=$(sudo morzer task run facts --output) || { unname; die "the facts task failed with a name"; }
[[ ${entry} == *" name=edge-1" ]] || { unname; die "relay-entry's line does not end with the relay's name"; }
[ "$(jq -r .name <<<"${facts}")" = edge-1 ] || { unname; die "the facts do not carry the relay's name"; }
sudo morzer config set name=bad/name >/dev/null || { unname; die "could not set a malformed name"; }
entry=$(sudo morzer task run relay-entry --output 2>/dev/null | grep -m1 '^127\.0\.0\.1 ' || true)
unname
if [ -z "${entry}" ] || [[ ${entry} == *name=* ]]; then die "relay-entry put a malformed name on its line, or none"; fi
echo "${0##*/}: relay-entry and the facts carry the relay's name; a malformed one neither"
