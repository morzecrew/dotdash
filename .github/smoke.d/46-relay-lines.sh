#!/usr/bin/env bash
# relay/1 lines (relays, as a relay's relay-entry prints them) and the server's
# name: a relay/1 line lets its relay in by the id relay-config prints it in a
# server/1 line, with no line in vless_clients, and deleting the line locks
# it out; a line of the release before, beside it, still gives its links;
# the server's own links are named by name; relay_flags' standby puts a
# relay's links last; client-config --relay prints that relay's links alone.
# No link or id is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

target=http://11.99.0.10:8000/
domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
dir=/rig/clients/relay-line
restore() {
  sudo docker rm -f dotdash-rig-relay-line >/dev/null 2>&1 || true
  sudo morzer config unset relay_flags >/dev/null 2>&1 || true
  sudo morzer config unset relays >/dev/null 2>&1 || true
  sudo morzer config unset name >/dev/null 2>&1 || true
}
trap restore EXIT
out() { sudo morzer task run client-config --output -- --full "$@"; }
shares() { grep -E '^(vless|hysteria2)://' <<<"$1" || true; }
gets_through() { # <socks port>
  curl -fsS -o /dev/null --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}

r1="relay/1 r1 0123456789abcdef relay-1.test relay-1.test pbkR000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.r1 xhttp=00112233445566778899aabbccddeeff"
old="198.51.100.7 site-b.test pbkB000000000000000000000000000000000000000 8899aabbccddeeff mlkem768x25519plus.native.0rtt.b name=old"
sudo morzer config set name=s1 >/dev/null || die "could not set name"
printf '%s\n%s\n' "${r1}" "${old}" | sudo morzer config set --set-file relays=- >/dev/null || die "could not set a relay/1 line and a line of before"

# relay-config prints the relay its server/1 line; a REALITY client with the
# relay's id there gets through, as the relay will.
read -r -a line < <(sudo morzer task run relay-config --output -- r1 2>/dev/null | grep -m1 '^server/1 ') ||
  die "relay-config printed no server/1 line for r1"
[ "${#line[@]}" = 8 ] && [ "${line[0]} ${line[1]} ${line[2]}" = "server/1 s1 ${domain}" ] ||
  die "relay-config's line is not server/1 s1 ${domain} <port> <pbk> <sid> <enc> <id>"
mkdir -p "${dir}"
jq -n --arg id "${line[7]}" --arg enc "${line[6]}" --arg sni "${domain}" --arg pbk "${line[4]}" --arg sid "${line[5]}" '
  {inbounds: [{listen: "127.0.0.1", port: 11100, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >"${dir}/client.json"
chmod -R a+rX "${dir}"
sudo docker rm -f dotdash-rig-relay-line >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-relay-line --network host -v "${dir}:/etc/xray:ro" "${xray}" >/dev/null
gets_through 11100 || die "the relay's id from its server/1 line does not get through"
! sudo grep -qiF "${line[7]}" /run/dotdash/secrets/vless_clients || die "the relay's id is in vless_clients"
echo "${0##*/}: a relay/1 line's relay gets in by the id its server/1 line carries, with no line in vless_clients"

# Links: the relay/1 line's and the line of before's, each by its name, and
# the server's own by name.
text=$(out)
links=$(shares "${text}")
devices=$(grep -c '#s1%20%C2%B7%20reality$' <<<"${links}" || true)
[ "${devices}" -ge 1 ] && ! grep -q '#server%20' <<<"${links}" || die "the server's own links are not named s1"
for want in '@relay-1\.test:443?.*#r1%20%C2%B7%20reality$' '@relay-1\.test:443?.*#r1%20%C2%B7%20xhttp$' '@198\.51\.100\.7:443?.*#old%20%C2%B7%20reality$'; do
  [ "$(grep -cE "${want}" <<<"${links}")" = "${devices}" ] || die "not a link per device matching ${want}"
done
echo "${0##*/}: a relay/1 line and a line of before each give their links, named by their names; the server's are named s1"

# relay_flags: standby puts r1's links last, and its outbounds outside the
# balancer; no restart of Xray for it.
since=$(sudo docker inspect -f '{{.State.StartedAt}}' "$(service_container xray)")
printf 'r1 standby\n' | sudo morzer config set --set-file relay_flags=- >/dev/null || die "could not set relay_flags"
text=$(out)
last=$(shares "${text}" | tail -n 1)
[[ ${last} == *"#r1%20%C2%B7%20reality" ]] || die "relay_flags' standby did not put r1's links last"
awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" |
  jq -e '.outbounds[0].tag | startswith("standby-relay-")' >/dev/null || die "relay_flags' standby did not put r1's outbound first, outside dotdash-"
[ "$(sudo docker inspect -f '{{.State.StartedAt}}' "$(service_container xray)")" = "${since}" ] || die "a relay_flags change restarted Xray"
echo "${0##*/}: relay_flags' standby puts a relay's links last, with no restart of Xray"

# --relay: that relay's links alone.
only=$(shares "$(out --relay r1)")
[ -n "${only}" ] && ! grep -qv '#r1%20%C2%B7%20' <<<"${only}" || die "client-config --relay r1 printed other links than r1's"
echo "${0##*/}: client-config --relay prints that relay's links alone"

# Deleting the relay/1 line revokes the relay.
printf '%s\n' "${old}" | sudo morzer config set --set-file relays=- >/dev/null || die "could not drop the relay/1 line"
sleep 3
! curl -fsS -o /dev/null --max-time 10 --socks5-hostname 127.0.0.1:11100 "${target}" 2>/dev/null ||
  die "the relay's id still gets through once its line is gone"
echo "${0##*/}: deleting a relay/1 line locks its relay out"
