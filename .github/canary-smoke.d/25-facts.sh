#!/usr/bin/env bash
# The facts task, which an authority reads before every fleet publish: what
# the canary watches, whether each transport gets through, and with
# control_url set, whether the canary's own network answers without dotdash.
# A freeze emulated on the stand-in server's connections (its packets dropped
# past 20 KB, the connection left open) fails REALITY with the bytes it got;
# stopping the stand-in server (pre-apply/10-server.sh) fails it outright.
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
jq -e '.server == "www.gstatic.com" and (.address | length > 0) and (.checked_at | type == "number")
  and .internet == null and .paths == {reality: true} and .stalled == {}' <<<"${got}" >/dev/null ||
  die "facts with the server up: ${got}"

sudo morzer config set control_url=https://www.gstatic.com/generate_204 >/dev/null || die "could not set control_url"
got=$(facts)
jq -e '.internet == true' <<<"${got}" >/dev/null || die "facts with control_url set: ${got}"
echo "25-facts.sh: ${got}"

# A network's DPI freezing a connection after its first 20 KB: the stand-in
# server's packets on 443 dropped once their connection has carried that much
# its way. In the server's own namespace, where every packet it sends passes
# OUTPUT whether the published port is NATed or proxied; its own connections
# out, to the sites, leave from other ports. probe_url's fetch stays under it;
# freeze_url doesn't.
# connbytes counts what conntrack accounts, which is off by default; an
# iptables that renders the match as nft's own ct bytes doesn't turn it on.
pid=$(sudo docker inspect -f '{{.State.Pid}}' canary-rig-server)
in_server() { sudo nsenter -t "${pid}" -n "$@"; }
freeze=(OUTPUT -p tcp --sport 443 -m connbytes --connbytes 20000: --connbytes-dir reply --connbytes-mode bytes -j DROP)
if in_server sysctl -qw net.netfilter.nf_conntrack_acct=1 2>/dev/null && in_server iptables -I "${freeze[@]}" 2>/dev/null; then
  got=$(facts) || true
  seen=$(in_server iptables -L OUTPUT -v -n -x | grep connbytes || true)
  in_server iptables -D "${freeze[@]}"
  jq -e '.internet == true and .paths == {reality: false} and .stalled.reality > 0 and .stalled.reality < 65536' \
    <<<"${got}" >/dev/null || die "facts with the server's connections frozen past 20 KB: ${got}; the rule: ${seen}"
  echo "25-facts.sh: frozen past 20 KB, REALITY reads down after $(jq .stalled.reality <<<"${got}") bytes"
  got=$(facts)
  jq -e '.paths == {reality: true} and .stalled == {}' <<<"${got}" >/dev/null || die "facts after the freeze: ${got}"
else
  echo "25-facts.sh: no connbytes match on this machine; the freeze is not tested"
fi

sudo docker stop canary-rig-server >/dev/null
got=$(facts) || true
sudo docker start canary-rig-server >/dev/null
jq -e '.internet == true and .paths == {reality: false}' <<<"${got}" >/dev/null ||
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
