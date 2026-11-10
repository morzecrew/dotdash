#!/usr/bin/env bash
# A backup proxy (upstream_backup_protocol, the upstream_backup secret). A
# stand-in backup connects everything it is asked for to the rig's target,
# which answers "ok" with 200; the upstream reaches the real sites. Which one
# carried a fetch of http://1.1.1.1/ shows in its status: Cloudflare's 301
# through the upstream, the target's 200 through the backup. An address, not a
# name: through the backup, DoH reaches the target too, and resolves nothing.
#
# - with both up, connections leave through the upstream;
# - with the upstream stopped, they move to the backup within the probes'
#   interval, and doctor passes;
# - with the upstream back, they return to it;
# - with the backup turned off, the upstream alone again.
#
# Needs the internet, as the upstream's way to 1.1.1.1.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  - name: upstream_backup$' /opt/dotdash/current/secrets.schema.yaml; then
  echo "${0##*/}: skipped, the installed release predates the backup proxy"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
pass=$(random)
mkdir -p /rig/backup
jq -n --arg pass "${pass}" '{log: {loglevel: "warning"},
  inbounds: [{listen: "0.0.0.0", port: 8080, protocol: "http", settings: {accounts: [{user: "rigb", pass: $pass}]}}],
  outbounds: [{protocol: "freedom", settings: {redirect: "11.99.0.10:8000"}}]}' >/rig/backup/upstream.json
chmod -R a+rX /rig/backup
sudo docker rm -f dotdash-rig-backup >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-backup --network dotdash-rig -p 18082:8080 \
  -v /rig/backup:/etc/xray:ro "${xray}" >/dev/null

restore() {
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo morzer config set upstream_backup_protocol=none >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-backup >/dev/null 2>&1 || true
}
trap restore EXIT

printf 'rigb:%s@%s:18082' "${pass}" "${host}" | sudo morzer secret set upstream_backup >/dev/null
sudo morzer config set upstream_backup_protocol=http >/dev/null \
  || die "could not turn on the backup proxy (its health check failed?)"

code() { # through 10-clients.sh's REALITY client: 301 through the upstream, 200 through the backup
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --socks5-hostname 127.0.0.1:11080 http://1.1.1.1/ 2>/dev/null || true
}
becomes() { # <code>: whether fetches answer with it within the probes' interval and some
  local _
  for _ in $(seq 30); do [ "$(code)" = "$1" ] && return 0; sleep 3; done
  return 1
}

becomes 301 || die "with both proxies up, connections do not leave through the upstream (last: $(code))"
echo "${0##*/}: with both up, connections leave through the upstream"

sudo docker stop dotdash-rig-upstream >/dev/null
becomes 200 || die "with the upstream stopped, connections do not move to the backup (last: $(code))"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the backup carrying: $(sudo morzer doctor 2>&1 | tail -3)"
echo "${0##*/}: with the upstream stopped, connections move to the backup, and doctor passes"

sudo docker start dotdash-rig-upstream >/dev/null
becomes 301 || die "once the upstream is back, connections do not return to it (last: $(code))"
echo "${0##*/}: with the upstream back, connections return to it"

sudo morzer config set upstream_backup_protocol=none >/dev/null || die "could not turn the backup proxy off"
sudo docker stop dotdash-rig-backup >/dev/null
becomes 301 || die "with the backup off, connections do not leave through the upstream (last: $(code))"
sudo jq -e '[.outbounds[].tag] | index("backup") | not' /etc/dotdash/gate.json >/dev/null \
  || die "the gate still has a backup outbound with upstream_backup_protocol=none"
echo "${0##*/}: with the backup off, the upstream alone"
