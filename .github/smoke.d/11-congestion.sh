#!/usr/bin/env bash
# TCP congestion control toward devices: the gate, which ends their TCP,
# runs BBR in its own namespace (tcp_congestion), and the 10-clients.sh
# clients get through on it; tcp_congestion=cubic moves it, and back.
# Running at all is the kernel's acceptance: a sysctl it refuses fails the
# container's start.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  tcp_congestion:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

target=http://11.99.0.10:8000/
cc() { sudo docker inspect -f '{{index .HostConfig.Sysctls "net.ipv4.tcp_congestion_control"}}' "$(service_container gate)"; }
gets_through() { # <socks port>
  [ "$(curl -fsS --max-time 15 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null)" = ok ]
}

[ "$(cc)" = bbr ] || die "the gate's congestion control is '$(cc)', not bbr"
gets_through 11080 || die "the first client does not get through with the gate on BBR"
sudo morzer config set tcp_congestion=cubic >/dev/null || die "could not set tcp_congestion=cubic"
[ "$(cc)" = cubic ] || die "tcp_congestion=cubic left the gate on '$(cc)'"
gets_through 11080 || die "the first client does not get through with the gate on cubic"
sudo morzer config unset tcp_congestion >/dev/null || die "could not unset tcp_congestion"
[ "$(cc)" = bbr ] || die "back on the default, the gate is on '$(cc)'"
echo "11-congestion.sh: the gate sends on BBR in its own namespace, and on cubic when told"
