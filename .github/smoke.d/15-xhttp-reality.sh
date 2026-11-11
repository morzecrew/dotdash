#!/usr/bin/env bash
# XHTTP with REALITY, the opt-in third transport, under each profile that has
# it. CI installs the xdns profile, and a published release that declares
# neither of these, so this switches to them at runtime and back:
#
# 1. xdns,xhttp-reality, two profiles combined: client-config adds a third
#    link and outbound, with no flow, and prints the first two links as before;
#    a client from the new link gets through on 8443, and so do
#    10-clients.sh's REALITY, XHTTP and DNS-tunnel clients. One with a wrong
#    id, public key or short id does not get through; with the upstream
#    stopped, nothing does.
# 2. xhttp-reality, on a port of its own: 53 is no longer published, the link
#    names the new port and works there, and 8443 is shut. xhttp_reality_port
#    equal to https_port or 80 is refused, and the deployment keeps serving.
# 3. xdns again, the rollback the docs give: the port is shut, client-config
#    prints exactly what it did before, and the first clients get through.
#
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'xhttp-reality:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

target=http://11.99.0.10:8000/
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
port() { local rest=${1#*@}; rest=${rest%%\?*}; echo "${rest##*:}"; }
links() { sudo morzer task run client-config --output | grep '^vless://'; }
full_config() { sudo morzer task run client-config --output |
  awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}'; }
published() { # <host port> <tcp|udp>: whether the gate publishes it
  sudo docker port "$(service_container gate)" | grep -qE "^[0-9]+/$2 -> .*:$1\$"
}
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

client() { # <name> <socks port> <link> [jq edit]: a client from the link, started
  local dir=/rig/clients/$1 link=$3
  mkdir -p "${dir}"
  jq -n --argjson socks "$2" --argjson port "$(port "${link}")" --arg id "$(id "${link}")" \
    --arg enc "$(param "${link}" encryption)" --arg sni "$(param "${link}" sni)" \
    --arg pbk "$(param "${link}" pbk)" --arg sid "$(param "${link}" sid)" \
    --arg path "/$(param "${link}" path | sed 's/^%2F//')" '
    {inbounds: [{listen: "127.0.0.1", port: $socks, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: "127.0.0.1", port: $port, id: $id, encryption: $enc},
       streamSettings: {network: "xhttp", security: "reality",
         realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid},
         xhttpSettings: {path: $path, mode: "auto"}}}]}' | jq "${4:-.}" >"${dir}/client.json"
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

before=$(links)
! grep -q 'security=reality.*type=xhttp' <<<"${before}" || die "client-config prints XHTTP with REALITY under the xdns profile"
! published 8443 tcp || die "8443 is published under the xdns profile"

# 1. Both optional transports, as two profiles combined.
both=xdns,xhttp-reality
set_config "installation.profile=${both}"
after=$(links)
grep -vxFf <(printf '%s\n' "${after}") <(printf '%s\n' "${before}") >/dev/null \
  && die "a link printed before changed once XHTTP with REALITY was added"
xr=$(grep -m1 '^vless://.*security=reality.*type=xhttp' <<<"${after}") \
  || die "client-config printed no XHTTP with REALITY link"
[[ ${xr} != *flow=* ]] || die "the XHTTP with REALITY link sets a flow"
[ "$(port "${xr}")" = 8443 ] || die "the XHTTP with REALITY link is not on 8443"
full_config | jq -e '
  [.outbounds[] | select(.tag | endswith("-xhttp-reality"))] as $xr
  | ($xr | length) == 1 and $xr[0].settings.port == 8443 and $xr[0].settings.flow == null
    and $xr[0].streamSettings.security == "reality" and $xr[0].streamSettings.network == "xhttp"
    and ([.outbounds[] | select(.tag | endswith("-reality") and (endswith("-xhttp-reality") | not))
      | .settings.flow] == ["xtls-rprx-vision"])' >/dev/null \
  || die "client-config's Xray config has no right XHTTP with REALITY outbound beside REALITY's"
published 53 udp || die "the DNS tunnel is not published under ${both}"
client xhttp-reality 11086 "${xr}"
gets_through 11086 || die "no answer through XHTTP with REALITY on 8443"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} no longer gets through under ${both}"
done
echo "15-xhttp-reality.sh: ${both} adds a third link, no flow, that works beside the others"

wrong_pbk=$(sudo docker run --rm "${xray}" x25519 | sed -n 's/^Password (PublicKey): //p')
[ -n "${wrong_pbk}" ] || die "xray x25519 printed no public key"
client wrong-id 11087 "${xr}" ".outbounds[0].settings.id = \"$(cat /proc/sys/kernel/random/uuid)\""
client wrong-pbk 11088 "${xr}" ".outbounds[0].streamSettings.realitySettings.password = \"${wrong_pbk}\""
client wrong-sid 11089 "${xr}" ".outbounds[0].streamSettings.realitySettings.shortId = \"$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')\""
for wrong in id:11087 pbk:11088 sid:11089; do
  locked_out "${wrong#*:}" || die "a client with a wrong ${wrong%:*} gets through XHTTP with REALITY"
  sudo docker rm -f "dotdash-rig-wrong-${wrong%:*}" >/dev/null
done
echo "15-xhttp-reality.sh: a wrong id, public key or short id gets nothing"

sudo docker stop dotdash-rig-upstream >/dev/null
if ! locked_out 11086; then
  sudo docker start dotdash-rig-upstream >/dev/null
  die "XHTTP with REALITY reached the target with the upstream stopped"
fi
sudo docker start dotdash-rig-upstream >/dev/null
gets_through 11086 || die "XHTTP with REALITY did not recover with the upstream"
echo "15-xhttp-reality.sh: with the upstream stopped, XHTTP with REALITY gets nothing"

# 2. Alone, on a port of its own.
set_config installation.profile=xhttp-reality
set_config xhttp_reality_port=9443
! published 53 udp || die "53 is still published under xhttp-reality"
! published 8443 tcp || die "8443 is still published with xhttp_reality_port=9443"
published 9443 tcp || die "9443 is not published with xhttp_reality_port=9443"
# Not links | grep -m1: links run to kilobytes, and once the XHTTP with REALITY
# link is no longer the last, grep -m1 exits before links' own grep flushes
# the rest, which dies of SIGPIPE and fails the pipe under pipefail.
xr=$(grep -m1 '^vless://.*security=reality.*type=xhttp' <<<"$(links)") || die "no XHTTP with REALITY link under xhttp-reality"
[ "$(port "${xr}")" = 9443 ] || die "the link does not name xhttp_reality_port"
client xhttp-reality 11086 "${xr}"
gets_through 11086 || die "no answer through XHTTP with REALITY on 9443"
for taken in 443 80; do
  if out=$(sudo morzer config set "xhttp_reality_port=${taken}" 2>&1); then
    die "xhttp_reality_port=${taken} was accepted"
  fi
  grep -qF 'xhttp_reality_port must' <<<"${out}" || die "xhttp_reality_port=${taken} failed, but not saying why: ${out}"
  gets_through 11086 || die "the deployment stopped serving after xhttp_reality_port=${taken} was refused"
done
echo "15-xhttp-reality.sh: xhttp-reality serves on xhttp_reality_port alone, and a taken port is refused"

# 3. Back.
set_config installation.profile=xdns
sudo morzer config unset xhttp_reality_port >/dev/null
! published 9443 tcp || die "9443 is still published after going back to xdns"
published 53 udp || die "the DNS tunnel is not published after going back to xdns"
[ "$(links)" = "${before}" ] || die "client-config prints other links after going back to xdns"
locked_out 11086 || die "XHTTP with REALITY still gets through after going back to xdns"
for p in 11080 11081 11082; do
  gets_through "${p}" || die "the client on ${p} does not get through after going back to xdns"
done
sudo docker rm -f dotdash-rig-xhttp-reality >/dev/null
echo "15-xhttp-reality.sh: back to xdns, the port is shut and the first links work as before"
