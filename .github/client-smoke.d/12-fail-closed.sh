#!/usr/bin/env bash
# Fail closed: with no links at all, as on a first start that cannot fetch the
# subscription, the proxy port refuses what would go through dotdash rather
# than sending it directly, while a direct rule still reaches its destination,
# which shows mihomo is up and routing. The real URL then brings the links
# back. Without "empty-fallback": "REJECT" the group would fall back to
# COMPATIBLE, mihomo's DIRECT.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
fetch() { # <URL>: its status through the proxy port, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://127.0.0.1:7890 "$1" || true
}

# A URL that answers 404, the direct rule, and no cached links.
printf 'http://%s:8088/none' "${host}" | sudo morzer secret set subscription_url >/dev/null
printf 'DOMAIN,example.com\n' | sudo morzer secret set direct_rules >/dev/null
home=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash-client_home)
sudo rm -f "${home}/proxies/dotdash.yaml"
sudo docker restart "$(service_container mihomo)" >/dev/null

up=
for _ in $(seq 30); do
  [ "$(fetch https://example.com/)" = 200 ] && { up=1; break; }
  sleep 2
done
[ -n "${up}" ] || die "with no links, even a direct rule's destination does not answer"
for _ in 1 2 3; do
  code=$(fetch https://www.gstatic.com/generate_204)
  [ "${code}" != 204 ] || die "with no links, traffic left directly instead of being refused"
  sleep 2
done

printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
printf '# none\n' | sudo morzer secret set direct_rules >/dev/null
for _ in $(seq 30); do
  [ "$(fetch https://www.gstatic.com/generate_204)" = 204 ] && break
  sleep 2
done
[ "$(fetch https://www.gstatic.com/generate_204)" = 204 ] || die "the links did not come back with the subscription"
echo "12-fail-closed.sh: with no links the port refuses, never sends directly; the links come back"
