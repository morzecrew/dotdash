#!/usr/bin/env bash
# After every other hook has exercised the bundle (clients on every transport,
# an upstream outage, a wrong password, restarts) and transfers are cut short
# here, the containers' logs hold
# no secret and no destination: not the XHTTP path, a client id, the upstream
# password, the REALITY short id or a share link, and not the rig's target. A
# leak is reported by what it is, never by its value.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before quiet logs has nothing to check.
if ! sudo grep -qF 'request delete' /opt/dotdash/current/caddy/Caddyfile; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

# Cut transfers short through both clients (10-clients.sh's, SOCKS on 11080
# and 11081): an XHTTP session aborted mid-response is what made Caddy log
# its URI, the secret path in it.
for port in 11080 11081; do
  for _ in 1 2 3; do
    curl -s -o /dev/null --max-time 0.3 --socks5-hostname "127.0.0.1:${port}" http://11.99.0.10:8000/blob || true
  done
done
sleep 1

logs=$(for c in $(sudo docker ps -aq --filter label=com.docker.compose.project=dotdash); do
  sudo docker logs "${c}" 2>&1
done)
[ -n "${logs}" ] || die "no container logs to check"

leak() { # <what> <value>
  [ -n "$2" ] || return 0
  if grep -qF -- "$2" <<<"${logs}"; then
    die "the containers' logs contain $1"
  fi
}
secrets=/run/dotdash/secrets
leak "the XHTTP path" "$(sudo cat "${secrets}/xhttp_path")"
leak "the upstream password" "$(sudo cat "${secrets}/upstream_password")"
leak "the REALITY short id" "$(sudo cat "${secrets}/reality_short_id")"
while read -r id _; do
  case ${id} in '' | '#'*) continue ;; esac
  leak "a client id" "${id}"
done < <(sudo cat "${secrets}/vless_clients")
leak "a share link" "vless://"
# The image prints its settings at start, healthcheck_url among them: the
# operator's own choice, here the same target the clients fetch.
logs=$(grep -v '^\[envconf\]' <<<"${logs}" || true)
leak "a destination (the rig's target)" "11.99.0.10:8000"
echo "50-quiet-logs.sh: no secret and no destination in $(wc -l <<<"${logs}") log lines"
