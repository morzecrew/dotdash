#!/usr/bin/env bash
# The leak lab. client-config's Xray config runs in a container of its own
# whose only resolver, 192.0.2.53, answers nothing, and every port-53 packet in
# its network namespace is captured. An inbound that forwards to 9.9.9.9:53
# stands in for an app's VPN mode handing the config the device's DNS. Those
# lookups must be answered through the tunnel with IPv4 addresses only and no
# port-53 packet; the upstream must be handed the DoH server's address, never
# the names; and with the upstream stopped they must fail rather than go
# anywhere else. Last, a lookup sent from the namespace on purpose shows the
# capture sees port-53 packets, so its silence means something.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer task run client-config --output)
config=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}")
if ! jq -e '.outbounds[] | select(.protocol == "dns")' <<<"${config}" >/dev/null; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi
sudo apk add --no-cache -q tcpdump bind-tools >/dev/null || die "could not add tcpdump and dig to the rig"

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
dir=/rig/clients/leak
# The capture outside the config's directory, where the image takes JSON only.
cap=/rig/leak-capture
mkdir -p "${dir}" "${cap}"
# Pointed at the rig as 10-clients.sh does, but on docker0, from outside the
# rig's own namespace. The DNS tunnel is left out: its queries are the tunnel.
jq --arg host "${host}" '
  .inbounds = [{listen: "0.0.0.0", port: 11095, protocol: "socks"},
    {listen: "0.0.0.0", port: 5353, protocol: "dokodemo-door",
     settings: {address: "9.9.9.9", port: 53, network: "tcp,udp"}}]
  | .outbounds |= map(select(.tag != "xdns")
      | (if .settings.address == "dotdash.test" then .settings.address = $host else . end)
      | (if .streamSettings.security == "tls"
         then .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]
         else . end))
  | del(.routing.balancers[0].fallbackTag)
  | .observatory.probeUrl = "http://11.99.0.10:8000/" | .observatory.probeInterval = "5s"' \
  <<<"${config}" >"${dir}/client.json"
chmod -R a+rX "${dir}"

capture=
cleanup() {
  [ -z "${capture}" ] || sudo kill "${capture}" 2>/dev/null || true
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-leak >/dev/null 2>&1 || true
}
trap cleanup EXIT
sudo docker rm -f dotdash-rig-leak >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-leak --dns 192.0.2.53 \
  -p 127.0.0.1:11095:11095 -p 127.0.0.1:15353:5353/udp -p 127.0.0.1:15353:5353/tcp \
  -v "${dir}:/etc/xray:ro" -v /rig/clients/root.pem:/ca/root.pem:ro "${xray}" >/dev/null
pid=$(sudo docker inspect -f '{{.State.Pid}}' dotdash-rig-leak)
# shellcheck disable=SC2024 # the files are the hook's own, not root's
sudo nsenter -t "${pid}" -n tcpdump -i any -nn -l 'port 53' >"${cap}/dns.txt" 2>"${cap}/tcpdump.err" &
capture=$!
for _ in $(seq 50); do grep -q 'listening on' "${cap}/tcpdump.err" && break; sleep 0.2; done
grep -q 'listening on' "${cap}/tcpdump.err" || die "the capture did not start"

through() {
  [ "$(curl -fsS --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname 127.0.0.1:11095 http://11.99.0.10:8000/)" = ok ]
}
through || die "the client config does not get through"

log=/rig/upstream-log/access.log
mark=$(wc -l <"${log}")
ask() { dig +time=5 +tries=2 -p 15353 @127.0.0.1 "$@"; }
a=$(ask +short one.one.one.one A) || true
grep -qx '1.1.1.1' <<<"${a}" || die "no A answer through the tunnel (${a:-nothing})"
aaaa=$(ask +noall +comments +answer one.one.one.one AAAA) || true
grep -q 'status: NOERROR' <<<"${aaaa}" || die "no answer to an AAAA query"
! grep -qE 'IN[[:space:]]+AAAA' <<<"${aaaa}" || die "an AAAA query got IPv6 addresses"
tcp=$(ask +tcp +short dns.google A) || true
grep -qx '8.8.8.8' <<<"${tcp}" || die "no A answer over TCP through the tunnel (${tcp:-nothing})"
seen=$(tail -n "+$((mark + 1))" "${log}")
grep -qF '1.1.1.1:443' <<<"${seen}" || die "the DoH did not go out through the upstream"
! grep -qE 'one\.one\.one\.one|dns\.google' <<<"${seen}" || die "the upstream was handed a name that was looked up"
[ ! -s "${cap}/dns.txt" ] || die "port-53 packets left the client: $(head -3 "${cap}/dns.txt")"
echo "${0##*/}: DNS is answered through the tunnel over DoH, IPv4 only, and no port-53 packet leaves"

sudo docker stop dotdash-rig-upstream >/dev/null
down=$(ask +short example.com A) || true
sudo docker start dotdash-rig-upstream >/dev/null
# dig prints its timeouts where an answer would be; an address is an answer.
! grep -qE '^[0-9]+(\.[0-9]+){3}$' <<<"${down}" || die "a lookup was answered with the upstream stopped"
[ ! -s "${cap}/dns.txt" ] || die "with the upstream stopped, port-53 packets left the client: $(head -3 "${cap}/dns.txt")"
through || die "the client config did not recover with the upstream"
echo "${0##*/}: with the upstream stopped, lookups fail and nothing goes elsewhere"

sudo nsenter -t "${pid}" -n dig +time=1 +tries=1 @192.0.2.53 control.invalid >/dev/null 2>&1 || true
sleep 1
grep -qF '192.0.2.53.53' "${cap}/dns.txt" || die "the capture missed a lookup sent on purpose, so its silence proves nothing"
echo "${0##*/}: the capture sees a lookup sent on purpose"
