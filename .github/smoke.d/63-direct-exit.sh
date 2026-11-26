#!/usr/bin/env bash
# A direct line: this server's own address as the way out, for a server on a
# residential line. With `direct` alone in upstreams, the apply's health check
# and doctor get out (to a real site: the rig's own target is on a network
# only the rig's upstream reaches), and the rig's upstream, which logs every
# connection, carries none of it. Then the rig's upstream comes back.
#
# Needs the internet, as the direct line's way to the probe.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

log=/rig/upstream-log/access.log
carried() { sudo sh -c "cat ${log} 2>/dev/null | wc -l"; }

sudo morzer config set probe_url=https://www.gstatic.com/generate_204 >/dev/null ||
  die "could not move probe_url to a site the internet serves"
printf 'name=home | direct\n' | sudo morzer secret set upstreams >/dev/null ||
  die "a direct line alone did not get out: the apply's health check failed"
sleep 3
before=$(carried)
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with a direct line alone"
for _ in 1 2 3; do
  sudo docker compose -p dotdash exec -T xray /usr/local/bin/xray-entrypoint healthcheck >/dev/null 2>&1 ||
    die "Xray does not get out through the direct line"
done
[ "$(carried)" = "${before}" ] || die "with a direct line alone, the rig's upstream still carried traffic"
echo "${0##*/}: a direct line alone gets out from the server's own address, past no upstream"

printf 'http://%s name=rig\n' "$(cat /rig/upstream.conn)" | sudo morzer secret set upstreams >/dev/null ||
  die "could not put the rig's upstream back"
sudo morzer config set probe_url=http://11.99.0.10:8000/ >/dev/null || die "could not put probe_url back"
