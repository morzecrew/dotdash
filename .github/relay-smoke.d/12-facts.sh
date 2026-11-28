#!/usr/bin/env bash
# What the relay tells an authority it follows (manifest `published`): the
# facts task's JSON is relay-entry's line, at entry_host, which relay-entry
# also takes when given no address; without either, both say what to set.
# They carry the relay's name and nonce, and each server group's state as
# the gateway's agent found it. A malformed name, which no server would take,
# is refused by both, and name can't be unset.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

restore() { sudo morzer config unset entry_host >/dev/null; }
if out=$(sudo morzer task run facts --output 2>&1); then die "facts ran with no entry_host and no own-site: ${out}"; fi
grep -q 'set entry_host' <<<"${out}" || die "facts without entry_host did not say to set it: ${out}"

sudo morzer config set entry_host=127.0.0.1 >/dev/null || die "could not set entry_host"
facts=$(sudo morzer task run facts --output) || { restore; die "the facts task failed"; }
entry=$(sudo morzer task run relay-entry --output | grep -m1 '^relay/1 ' || true)
restore
[ -n "${entry}" ] || die "relay-entry with entry_host and no argument printed no relay/1 line"
read -r _ name nonce host site pbk sid enc _ <<<"${entry}"
[ "${host}" = 127.0.0.1 ] || die "relay-entry with entry_host=127.0.0.1 gave the host as ${host}"
want=$(jq -nc --arg n "${name}" --arg o "${nonce}" --arg h "${host}" --arg s "${site}" --arg p "${pbk}" --arg i "${sid}" --arg e "${enc}" \
  '{name: $n, nonce: $o, entry_host: $h, site: $s, public_key: $p, short_id: $i, encryption: $e}')
got=$(jq -c '{name, nonce, entry_host, site, public_key, short_id, encryption}' <<<"${facts}") || die "the facts are not JSON: ${facts}"
[ "${got}" = "${want}" ] || die "the facts are not relay-entry's line: ${got} against ${want}"
jq -e 'has("clients") or has("via") | not' <<<"${facts}" >/dev/null || die "the facts still carry clients or via"
echo "${0##*/}: facts are relay-entry's line at entry_host, with its name and nonce, and relay-entry takes entry_host too"

# Each group by name: live, its server answering, one device, the digest of
# its list as the server serves it (the stand-in's one file that is no
# subscription), and its age.
list=$(find /rig/relay/web -type f ! -name "$(cat /rig/relay/token)*")
digest=$(sha256sum <"${list}" | cut -c1-8)
got=$(jq -c '.groups.s1 | {state, servers, devices, digest, age: (.list_age < 120)}' <<<"${facts}")
[ "${got}" = "{\"state\":\"live\",\"servers\":{\"www.gstatic.com\":true},\"devices\":1,\"digest\":\"${digest}\",\"age\":true}" ] ||
  die "the facts' group s1 is not live with its server, one device, digest ${digest} and a recent list: $(jq -c .groups <<<"${facts}")"
echo "${0##*/}: the facts carry each server group's state, servers, devices, list digest and age"

# A malformed name: relay-entry and the facts refuse it, as no server would
# take the line; and name can't be unset.
unname() { sudo morzer config set name=r1 >/dev/null; sudo morzer config unset entry_host >/dev/null; }
sudo morzer config set entry_host=127.0.0.1 name=bad/name >/dev/null || { unname; die "could not set a malformed name"; }
if out=$(sudo morzer task run relay-entry --output 2>&1); then unname; die "relay-entry printed a line for a malformed name: ${out}"; fi
grep -q 'name is not 1 to 24' <<<"${out}" || { unname; die "relay-entry refused a malformed name without saying why: ${out}"; }
! sudo morzer task run facts --output >/dev/null 2>&1 || { unname; die "the facts went out with a malformed name"; }
unname
! sudo morzer config unset name >/dev/null 2>&1 || { sudo morzer config set name=r1 >/dev/null; die "name, required, was unset"; }
echo "${0##*/}: relay-entry and the facts refuse a malformed name, and name can't be unset"
