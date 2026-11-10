#!/usr/bin/env bash
# VLESS over mKCP, the opt-in UDP transport. CI installs the xdns profile, so
# this switches to xdns,mkcp at runtime and back:
#
# 1. xdns,mkcp: client-config adds an mKCP link and outbound per server, with
#    the seed and kcp_header, and prints the other links as before; the gate
#    publishes 8447/udp; a client from the link gets through, and so do
#    10-clients.sh's; one with a wrong seed or header does not, and with the
#    upstream stopped nothing does.
# 2. kcp_port and kcp_header changed: the link follows and works there;
#    kcp_port=53 beside the DNS tunnel is refused, and the deployment keeps
#    serving.
# 3. xdns again: the port is shut, client-config prints exactly what it did
#    before, and the first clients get through.
#
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'mkcp: [compose/mkcp.yaml]' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

target=http://11.99.0.10:8000/
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
port() { local rest=${1#*@}; rest=${rest%%\?*}; echo "${rest##*:}"; }
# Captured, then read: a reader that stops early would kill the task's output.
links() { local out; out=$(sudo morzer task run client-config --output); grep '^vless://' <<<"${out}"; }
kcp_link() { local all; all=$(links); grep -m1 '^vless://.*type=kcp' <<<"${all}"; }
full_config() {
  local out; out=$(sudo morzer task run client-config --output)
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}"
}
published() { # <host port> <tcp|udp>: whether the gate publishes it
  sudo docker port "$(service_container gate)" | grep -qE "^[0-9]+/$2 -> .*:$1\$"
}
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

client() { # <name> <socks port> <link> [seed] [header]: an mKCP client from the link, started
  local dir=/rig/clients/$1 link=$3 seed header
  seed=${4:-$(param "$3" seed)}
  header=${5:-$(param "$3" headerType)}
  mkdir -p "${dir}"
  jq -n --argjson socks "$2" --argjson port "$(port "${link}")" --arg id "$(id "${link}")" \
    --arg enc "$(param "${link}" encryption)" --arg seed "${seed}" --arg header "${header}" '
    {inbounds: [{listen: "127.0.0.1", port: $socks, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: "127.0.0.1", port: $port, id: $id, encryption: $enc},
       streamSettings: {network: "kcp", finalmask: {udp:
         ([{type: "mkcp-legacy", settings: {value: $seed}}]
          + (if $header == "none" then [] else [{type: "mkcp-legacy", settings: {header: $header}}] end))}}}]}' \
    >"${dir}/client.json"
  chmod -R a+rX "${dir}"
  sudo docker rm -f "dotdash-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-$1" --network host -v "${dir}:/etc/xray:ro" "${xray}" >/dev/null
}
gets_through() { # <socks port>
  [ "$(curl -fsS --max-time 15 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null)" = ok ]
}
locked_out() { # <socks port>
  sleep 2
  ! curl -fsS -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}
cleanup() { for c in kcp kcp-seed kcp-header kcp-moved; do sudo docker rm -f "dotdash-rig-$c" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

before=$(links)
! grep -q 'type=kcp' <<<"${before}" || die "client-config prints an mKCP link under the xdns profile"
! published 8447 udp || die "8447/udp is published under the xdns profile"

# 1. Beside the DNS tunnel.
set_config installation.profile=xdns,mkcp
after=$(links)
grep -vxFf <(printf '%s\n' "${after}") <(printf '%s\n' "${before}") >/dev/null \
  && die "a link printed before changed once mKCP was added"
kl=$(grep -m1 '^vless://.*type=kcp' <<<"${after}") || die "client-config printed no mKCP link"
[ "$(port "${kl}")" = 8447 ] || die "the mKCP link is not on 8447"
[ "$(param "${kl}" headerType)" = srtp ] || die "the mKCP link's header is not the default srtp"
[[ $(param "${kl}" seed) =~ ^[0-9a-f]{32}$ ]] || die "the mKCP link carries no 32-hex seed"
[[ ${kl} != *flow=* && ${kl} != *security=* ]] || die "the mKCP link sets a flow or a security"
full_config | jq -e --arg seed "$(param "${kl}" seed)" '
  [.outbounds[] | select(.tag | endswith("-kcp"))] as $k
  | ($k | length) == 1 and $k[0].settings.port == 8447 and $k[0].streamSettings.network == "kcp"
    and $k[0].streamSettings.finalmask.udp == [
      {type: "mkcp-legacy", settings: {value: $seed}}, {type: "mkcp-legacy", settings: {header: "srtp"}}]' >/dev/null \
  || die "client-config's Xray config has no mKCP outbound matching the link"
published 8447 udp || die "8447/udp is not published under xdns,mkcp"
published 53 udp || die "the DNS tunnel is not published under xdns,mkcp"
client kcp 11091 "${kl}"
gets_through 11091 || die "no answer through mKCP on 8447"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} no longer gets through under xdns,mkcp"
done
echo "17-mkcp.sh: xdns,mkcp adds an mKCP link and outbound that work beside the others"

client kcp-seed 11092 "${kl}" "$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
client kcp-header 11093 "${kl}" "" dtls
locked_out 11092 || die "a client with a wrong seed gets through mKCP"
locked_out 11093 || die "a client with a wrong header gets through mKCP"
echo "17-mkcp.sh: a wrong seed or header gets nothing"

sudo docker stop dotdash-rig-upstream >/dev/null
if ! locked_out 11091; then
  sudo docker start dotdash-rig-upstream >/dev/null
  die "mKCP reached the target with the upstream stopped"
fi
sudo docker start dotdash-rig-upstream >/dev/null
gets_through 11091 || die "mKCP did not recover with the upstream"
echo "17-mkcp.sh: with the upstream stopped, mKCP gets nothing"

# 2. Another port, no header; 53 refused beside the DNS tunnel.
set_config kcp_port=9447 kcp_header=none
! published 8447 udp || die "8447/udp is still published with kcp_port=9447"
published 9447 udp || die "9447/udp is not published with kcp_port=9447"
kl=$(kcp_link) || die "no mKCP link with kcp_port=9447"
[ "$(port "${kl}")" = 9447 ] && [ "$(param "${kl}" headerType)" = none ] \
  || die "the mKCP link does not name kcp_port=9447 and no header"
locked_out 11091 || die "the srtp client still gets through with kcp_header=none"
client kcp-moved 11094 "${kl}"
gets_through 11094 || die "no answer through mKCP on 9447 with no header"
if out=$(sudo morzer config set kcp_port=53 2>&1); then
  die "kcp_port=53 was accepted beside the DNS tunnel"
fi
grep -qF 'kcp_port must not be 53' <<<"${out}" || die "kcp_port=53 failed, but not saying why: ${out}"
gets_through 11094 || die "the deployment stopped serving after kcp_port=53 was refused"
echo "17-mkcp.sh: kcp_port and kcp_header move the link, and 53 is refused beside the DNS tunnel"

# 3. Back.
set_config installation.profile=xdns
sudo morzer config unset kcp_port kcp_header >/dev/null || die "could not unset kcp_port and kcp_header"
! published 9447 udp || die "9447/udp is still published after going back to xdns"
published 53 udp || die "the DNS tunnel is not published after going back to xdns"
[ "$(links)" = "${before}" ] || die "client-config prints other links after going back to xdns"
locked_out 11094 || die "mKCP still gets through after going back to xdns"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} does not get through after going back to xdns"
done
echo "17-mkcp.sh: back to xdns, the port is shut and the first links work as before"
