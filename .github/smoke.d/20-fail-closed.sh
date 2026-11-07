#!/usr/bin/env bash
# Traffic leaves through the upstream or not at all, and `doctor` names the
# layer when it cannot. Uses 10-clients.sh's clients (SOCKS on 11080, 11081)
# and pre-apply/10-rig.sh's upstream.
#
# (The rendered config's invariants are hooks/policy's, tested in
# 25-policy.sh.)
#
# 1. A destination the server reaches directly (Caddy's port 80, on the
#    bundle's network) is unreachable through the tunnel, since the upstream
#    cannot resolve it: no direct path exists.
# 2. With the upstream stopped, clients get nothing and doctor fails, naming
#    the upstream's address; started again, both recover.
# 3. With a wrong upstream password, doctor fails naming the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before the egress check has nothing to check.
if ! sudo grep -qF 'name: egress' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi


through() { # <socks port> <url>: fetch through a client
  curl -fsS -o /dev/null --max-time 15 --socks5-hostname "127.0.0.1:$1" "$2"
}
caddy=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' caddy | sed -n 1p)
sudo docker run --rm --network "container:$(service_container xray)" "${caddy}" nc -z -w 3 caddy 80 \
  || die "the control failed: Xray's network does not reach caddy:80 directly"
for port in 11080 11081; do
  if through "${port}" http://caddy:80/ 2>/dev/null; then
    die "a client on ${port} reached caddy:80, which only a direct path reaches"
  fi
done
echo "20-fail-closed.sh: a destination only a direct path reaches is unreachable through the tunnel"

doctor() { # stdout: doctor's output on one line; status: doctor's
  local out status=0
  out=$(sudo morzer doctor 2>&1) || status=$?
  tr '\n' ' ' <<<"${out}" | tr -s ' '
  return "${status}"
}
fails_naming() { # <phrase>
  local out
  if out=$(doctor); then
    die "doctor passes with $1 expected: ${out}"
  fi
  grep -qF "$1" <<<"${out}" || die "doctor failed, but does not say '$1': ${out}"
}
recovers() {
  local out
  for _ in $(seq 12); do
    out=$(doctor) && return 0
    sleep 5
  done
  die "doctor still fails after the fault was undone: ${out}"
}

sudo docker stop dotdash-rig-upstream >/dev/null
if through 11080 http://target:8000/ 2>/dev/null; then
  sudo docker start dotdash-rig-upstream >/dev/null
  die "a client still reached the target with the upstream stopped"
fi
fails_naming "cannot connect to the upstream proxy"
sudo docker start dotdash-rig-upstream >/dev/null
recovers
through 11080 http://target:8000/ || die "the client did not recover with the upstream"
echo "20-fail-closed.sh: upstream stopped, clients get nothing and doctor names the upstream; both recover"

printf wrong | sudo morzer secret set upstream_password >/dev/null
fails_naming "refused the credentials"
printf '%s' "$(cat /rig/upstream.pass)" | sudo morzer secret set upstream_password >/dev/null
recovers
echo "20-fail-closed.sh: a wrong upstream password, and doctor names the credentials"
