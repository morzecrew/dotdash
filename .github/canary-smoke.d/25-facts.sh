#!/usr/bin/env bash
# The facts task, which an authority reads before every fleet publish: what
# the canary watches, whether each transport gets through, and with
# control_url set, whether the canary's own network answers without dotdash.
# A freeze_url that stops after 20 KB fails REALITY with the bytes it got;
# stopping the stand-in server (pre-apply/10-server.sh) fails it outright. A
# path that is up has its fetch's milliseconds, and control_url its own.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  facts:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

facts() {
  local out
  out=$(sudo morzer task run facts --output 2>&1) || die "facts failed: ${out}"
  grep -m1 '^{' <<<"${out}"
}

got=$(facts)
jq -e '.server == "www.gstatic.com" and (.address | length > 0) and (.public_key | length > 0) and (.checked_at | type == "number")
  and .internet == null and .paths == {reality: true} and .reality_split == true and .udp == {reality: true}
  and .blocked_by == null and .ipv6 == {}
  and .stalled == {} and .stalled_up == []
  and (.latency_ms | keys) == ["reality"] and .latency_ms.reality > 0 and .direct_ms == null' <<<"${got}" >/dev/null ||
  die "facts with the server up: ${got}"

sudo morzer config set control_url=https://www.gstatic.com/generate_204 >/dev/null || die "could not set control_url"
got=$(facts)
jq -e '.internet == true and .direct_ms > 0' <<<"${got}" >/dev/null || die "facts with control_url set: ${got}"
echo "25-facts.sh: ${got}"

# A freeze as the canary meets one: the bytes stop partway. A stand-in for
# freeze_url on the rig (openssl; the rig has no python) answers each of
# facts' two tries with 20 KB of a 64 KB body and then closes: cut, which
# counts as stalled does. The stand-in server reaches it on docker0.
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
dir=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=stall \
  -keyout "${dir}/key.pem" -out "${dir}/cert.pem" 2>/dev/null
for _ in 1 2; do
  { printf 'HTTP/1.1 200 OK\r\nContent-Length: 65536\r\nConnection: close\r\n\r\n'; head -c 20000 /dev/zero; } |
    openssl s_server -quiet -naccept 1 -accept "${host}:9443" -cert "${dir}/cert.pem" -key "${dir}/key.pem" \
      >/dev/null 2>&1
done &
stall=$!
sleep 1
sudo morzer config set "freeze_url=https://${host}:9443/f" >/dev/null || die "could not set freeze_url"
got=$(facts) || true
sudo morzer config unset freeze_url >/dev/null || die "could not unset freeze_url"
kill "${stall}" 2>/dev/null || true
jq -e '.internet == true and .paths == {reality: false} and .blocked_by == "freeze" and .stalled.reality > 0 and .stalled.reality < 65536
  and .latency_ms == {}' \
  <<<"${got}" >/dev/null || die "facts with freeze_url stopping after 20 KB: ${got}"
echo "25-facts.sh: freeze_url stopped after 20 KB: REALITY reads down after $(jq .stalled.reality <<<"${got}") bytes"
got=$(facts)
jq -e '.paths == {reality: true} and .stalled == {} and .stalled_up == []' <<<"${got}" >/dev/null ||
  die "facts after the freeze: ${got}"

# The other way: a stand-in for freeze_up_url reads each of facts' two
# uploads and never answers, as a freeze on what the device sends looks.
sleep 40 | openssl s_server -quiet -naccept 2 -accept "${host}:9443" -cert "${dir}/cert.pem" -key "${dir}/key.pem" \
  >/dev/null 2>&1 &
sleep 1
sudo morzer config set "freeze_up_url=https://${host}:9443/up" >/dev/null || die "could not set freeze_up_url"
got=$(facts) || true
sudo morzer config unset freeze_up_url >/dev/null || die "could not unset freeze_up_url"
jq -e '.paths == {reality: false} and .blocked_by == "freeze" and .stalled == {} and .stalled_up == ["reality"]' <<<"${got}" >/dev/null ||
  die "facts with freeze_up_url never answering: ${got}"
echo "25-facts.sh: freeze_up_url never answered: REALITY reads down, stalled_up"

sudo docker stop canary-rig-server >/dev/null
got=$(facts) || true
sudo docker start canary-rig-server >/dev/null
jq -e '.internet == true and .paths == {reality: false} and .reality_split == false and .udp == {reality: false}
  and .blocked_by == "ip"' <<<"${got}" >/dev/null ||
  die "facts with the server stopped: ${got}"
sudo morzer config unset control_url >/dev/null || die "could not unset control_url"
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "25-facts.sh: with the server stopped, REALITY does not get through and the network still answers"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
