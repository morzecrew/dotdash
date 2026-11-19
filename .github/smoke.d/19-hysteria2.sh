#!/usr/bin/env bash
# Hysteria2, the opt-in QUIC transport. CI installs the xdns profile, so this
# switches to xdns,hysteria2 at runtime and back:
#
# 1. xdns,hysteria2: client-config adds a Hysteria2 link and outbound per
#    server, named by the site's own name, and prints the other links as
#    before; the gate publishes 443/udp; a client from the link, trusting the
#    site's certificate (Caddy's own CA here, cert_issuer=internal), gets
#    through, and so do 10-clients.sh's; one with another login does not, and
#    with the upstream stopped nothing does.
# 2. hysteria2_up: the inbound turns to Brutal at that rate, and a client
#    asking for it still gets through; 0 again is BBR.
# 3. xdns again: the port is shut, client-config prints exactly what it did
#    before, and the first clients get through.
#
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'hysteria2: [compose/hysteria2.yaml]' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

target=http://11.99.0.10:8000/
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
auth() { local rest=${1#hysteria2://}; echo "${rest%%@*}"; }
port() { local rest=${1#*@}; rest=${rest%%/*}; echo "${rest##*:}"; }
# Captured, then read: a reader that stops early would kill the task's output.
links() { local out; out=$(sudo morzer task run client-config --output); grep -E '^(vless|hysteria2)://' <<<"${out}"; }
hy2_link() { local all; all=$(links); grep -m1 '^hysteria2://' <<<"${all}"; }
full_config() {
  local out; out=$(sudo morzer task run client-config --output)
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}"
}
published() { # <host port> <tcp|udp>: whether the gate publishes it
  sudo docker port "$(service_container gate)" | grep -qE "^[0-9]+/$2 -> .*:$1\$"
}
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
# The site's CA: Caddy's own, under cert_issuer=internal, from its data.
ca_dir=/rig/clients/hy2-ca
sudo mkdir -p "${ca_dir}"

client() { # <name> <socks port> <link> [auth] [brutal Mbit/s]: a Hysteria2 client from the link, started
  local dir=/rig/clients/$1 link=$3
  mkdir -p "${dir}"
  jq -n --argjson socks "$2" --argjson port "$(port "${link}")" --arg auth "${4:-$(auth "${link}")}" \
    --arg sni "$(param "${link}" sni)" --arg brutal "${5:-}" '
    {inbounds: [{listen: "127.0.0.1", port: $socks, protocol: "socks"}],
     outbounds: [{protocol: "hysteria", settings: {version: 2, address: "127.0.0.1", port: $port},
       streamSettings: {network: "hysteria", security: "tls",
         tlsSettings: {serverName: $sni, alpn: ["h3"],
           certificates: [{usage: "verify", certificateFile: "/ca/root.crt"}]},
         hysteriaSettings: {version: 2, auth: $auth},
         finalmask: {quicParams: (if $brutal == "" then {congestion: "bbr"}
           else {congestion: "brutal", brutalUp: "\($brutal) mbps", brutalDown: "\($brutal) mbps"} end)}}}]}' \
    >"${dir}/client.json"
  chmod -R a+rX "${dir}"
  sudo docker rm -f "dotdash-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-$1" --network host -v "${dir}:/etc/xray:ro" -v "${ca_dir}:/ca:ro" "${xray}" >/dev/null
}
gets_through() { # <socks port>
  [ "$(curl -fsS --max-time 15 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null)" = ok ]
}
locked_out() { # <socks port>
  sleep 2
  ! curl -fsS -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}
cleanup() { for c in hy2 hy2-auth hy2-brutal; do sudo docker rm -f "dotdash-rig-$c" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

before=$(links)
! grep -q '^hysteria2://' <<<"${before}" || die "client-config prints a Hysteria2 link under the xdns profile"
! published 443 udp || die "443/udp is published under the xdns profile"

# 1. Beside the DNS tunnel.
set_config installation.profile=xdns,hysteria2
after=$(links)
grep -vxFf <(printf '%s\n' "${after}") <(printf '%s\n' "${before}") >/dev/null \
  && die "a link printed before changed once Hysteria2 was added"
hl=$(hy2_link) || die "client-config printed no Hysteria2 link"
[ "$(port "${hl}")" = 443 ] || die "the Hysteria2 link is not on 443"
[[ $(auth "${hl}") =~ ^[0-9a-f-]{36}$ ]] || die "the Hysteria2 link's login is not the device's UUID"
[ -n "$(param "${hl}" sni)" ] || die "the Hysteria2 link names no sni"
full_config | jq -e --arg auth "$(auth "${hl}")" '
  [.outbounds[] | select(.tag | endswith("-hy2"))] as $h
  | ($h | length) == 1 and $h[0].protocol == "hysteria" and $h[0].settings.port == 443
    and $h[0].streamSettings.hysteriaSettings.auth == $auth
    and $h[0].streamSettings.finalmask.quicParams == {keepAlivePeriod: 10}' >/dev/null \
  || die "client-config's Xray config has no Hysteria2 outbound matching the link, with keepalives"
published 443 udp || die "443/udp is not published under xdns,hysteria2"
sudo morzer task run facts --output | jq -e '.hysteria2_port == 443' >/dev/null \
  || die "the facts carry no hysteria2_port under xdns,hysteria2"
published 53 udp || die "the DNS tunnel is not published under xdns,hysteria2"
data=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash_caddy_data)
sudo cp "${data}/caddy/pki/authorities/local/root.crt" "${ca_dir}/root.crt"
sudo chmod -R a+rX "${ca_dir}"
client hy2 11096 "${hl}"
gets_through 11096 || die "no answer through Hysteria2 on 443/udp: $(sudo docker logs --tail 5 dotdash-rig-hy2 2>&1)"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} no longer gets through under xdns,hysteria2"
done
echo "19-hysteria2.sh: xdns,hysteria2 adds a Hysteria2 link and outbound that work beside the others"

client hy2-auth 11097 "${hl}" "$(cat /proc/sys/kernel/random/uuid)"
locked_out 11097 || die "a client with another login gets through Hysteria2"
echo "19-hysteria2.sh: another login gets nothing"

sudo docker stop dotdash-rig-upstream >/dev/null
if ! locked_out 11096; then
  sudo docker start dotdash-rig-upstream >/dev/null
  die "Hysteria2 reached the target with the upstream stopped"
fi
sudo docker start dotdash-rig-upstream >/dev/null
gets_through 11096 || die "Hysteria2 did not recover with the upstream"
echo "19-hysteria2.sh: with the upstream stopped, Hysteria2 gets nothing"

# 2. Brutal toward a device that asks for it, then BBR again.
set_config hysteria2_up=50
config=/etc/dotdash/application.yaml
sudo jq -e '[.inbounds[] | select(.tag == "hysteria2")][0].streamSettings.finalmask.quicParams
  == {disableStatelessReset: true, maxIdleTimeout: 15, congestion: "brutal", brutalUp: "50 mbps"}' "${config}" >/dev/null \
  || die "hysteria2_up=50 did not put the inbound on Brutal at 50 Mbit/s"
client hy2-brutal 11098 "${hl}" "" 20
gets_through 11098 || die "no answer through Hysteria2 on Brutal"
sudo morzer config unset hysteria2_up >/dev/null || die "could not unset hysteria2_up"
sudo jq -e '[.inbounds[] | select(.tag == "hysteria2")][0].streamSettings.finalmask.quicParams
  == {disableStatelessReset: true, maxIdleTimeout: 15, congestion: "bbr"}' \
  "${config}" >/dev/null || die "hysteria2_up unset did not put the inbound back on BBR"
echo "19-hysteria2.sh: hysteria2_up turns Brutal on toward a device that asks, and 0 is BBR"

# 3. Back.
set_config installation.profile=xdns
! published 443 udp || die "443/udp is still published after going back to xdns"
sudo morzer task run facts --output | jq -e 'has("hysteria2_port") | not' >/dev/null \
  || die "the facts still carry hysteria2_port after going back to xdns"
published 53 udp || die "the DNS tunnel is not published after going back to xdns"
[ "$(links)" = "${before}" ] || die "client-config prints other links after going back to xdns"
locked_out 11096 || die "Hysteria2 still gets through after going back to xdns"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} does not get through after going back to xdns"
done
echo "19-hysteria2.sh: back to xdns, the port is shut and the first links work as before"
