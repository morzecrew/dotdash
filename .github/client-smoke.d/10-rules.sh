#!/usr/bin/env bash
# The client's promise: the proxy port gets out through dotdash (the stand-in,
# pre-apply/10-server.sh); a block rule refuses its destination; a direct rule
# reaches its destination with dotdash gone; and unset, neither does
# anything. A "#" line is a comment.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

fetch() { # the status of probe_url through the proxy port, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://127.0.0.1:7890 \
    https://www.gstatic.com/generate_204 || true
}
until_status() { # <want|!want> <what>: poll for a minute, as morzer restarts mihomo
  local code
  for _ in $(seq 30); do
    code=$(fetch)
    case $1 in '!'*) [ "${code}" != "${1#!}" ] && return 0 ;; *) [ "${code}" = "$1" ] && return 0 ;; esac
    sleep 2
  done
  die "$2 (last status ${code})"
}
unset_rules() { sudo morzer config unset "$1" >/dev/null; }

until_status 204 "the proxy port does not get out through dotdash"

printf 'DOMAIN-SUFFIX,gstatic.com\n' | sudo morzer config set --set-file block_rules=- >/dev/null
until_status '!204' "a block rule does not refuse its destination"
unset_rules block_rules
until_status 204 "unset block rules still refuse"

printf '# through no proxy\nDOMAIN-SUFFIX,gstatic.com\n' | sudo morzer config set --set-file direct_rules=- >/dev/null
sudo docker stop client-rig-server >/dev/null
until_status 204 "a direct rule's destination needs dotdash"
unset_rules direct_rules
until_status '!204' "with direct rules unset, it got out with dotdash gone"
sudo docker start client-rig-server >/dev/null
until_status 204 "the proxy port does not get out once dotdash is back"
echo "10-rules.sh: out through dotdash, a block rule refuses, a direct rule needs no dotdash"
