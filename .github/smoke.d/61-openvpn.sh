#!/usr/bin/env bash
# OpenVPN lines in the upstreams secret (`openvpn://`, the openvpn profile): an
# OpenVPN client (vpn) with a tunnel for each line, the k-th on tun<k>, and a
# SOCKS hop in its namespace (vpn-socks) that the gate dials at vpn:1080+k. A
# stand-in server, the bundle's openvpn image in server mode, carries the rig's
# traffic on to the target, with the rig's HTTP proxy stopped so nothing can
# leave through it:
#
# - openvpn-line prints a config's line, which leads nowhere while the profile
#   is off, the proxy still carrying traffic;
# - with the profile on, a dead line first and a live one second, pinned, a
#   client reaches the target through tun1, doctor passes, vpn reports each
#   tunnel, and it has no default route around them;
# - with the server stopped, nothing gets through, and doctor names each
#   OpenVPN line by its tunnel;
# - a new list while OpenVPN runs restarts vpn, and vpn-socks after it in
#   vpn's new network namespace, and traffic flows again;
# - openvpn killed inside vpn starts again in place: vpn doesn't restart,
#   vpn-socks stays in its namespace, and traffic flows again;
# - the proxy's line, then the xdns profile CI installs, go back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

schema=/opt/dotdash/current/secrets.schema.yaml
if ! sudo grep -q '^  - name: upstreams$' "${schema}" || sudo grep -q '^  - name: upstream_openvpn$' "${schema}"; then
  echo "${0##*/}: skipped, the installed release keeps OpenVPN's config out of the upstreams list"
  exit 0
fi
one="http://$(cat /rig/upstream.conn) name=rig"
list() { printf '%s\n' "$@" | sudo morzer secret set upstreams >/dev/null; }

openvpn=$(sudo sed -n 's/^  openvpn: *//p' /opt/dotdash/current/manifest.yaml)
[ -n "${openvpn}" ] || die "the installed manifest names no openvpn image"
sudo docker pull -q "${openvpn}" >/dev/null
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
target=http://11.99.0.10:8000/

# A throwaway PKI. remote-cert-tls refuses a certificate without a key usage.
pki=/rig/ovpn
mkdir -p "${pki}"
(
  cd "${pki}"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 \
    -subj /CN=rig-ca -keyout ca.key -out ca.crt
  for side in server client; do
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
      -subj "/CN=${side}" -keyout "${side}.key" -out "${side}.csr"
    printf 'keyUsage=critical,digitalSignature,keyAgreement\nextendedKeyUsage=%s\n' \
      "$([ "${side}" = server ] && echo serverAuth || echo clientAuth)" >"${side}.ext"
    openssl x509 -req -in "${side}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 \
      -extfile "${side}.ext" -out "${side}.crt"
  done
) >/dev/null 2>&1 || die "could not make the test PKI"
chmod -R a+rX "${pki}"

# The stand-in server masquerades the tunnel's subnet, so the target's replies
# find their way back; its image has no iptables, so it adds them.
sudo docker rm -f dotdash-rig-ovpn >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-ovpn --network dotdash-rig --cap-add NET_ADMIN \
  --device /dev/net/tun --sysctl net.ipv4.ip_forward=1 -p 1194:1194/udp -v "${pki}:/pki:ro" \
  --entrypoint sh "${openvpn}" -c '
  apk add --no-cache iptables >/dev/null && iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -j MASQUERADE &&
  exec openvpn --dev tun --proto udp --port 1194 --topology subnet --server 10.8.0.0 255.255.255.0 \
    --ca /pki/ca.crt --cert /pki/server.crt --key /pki/server.key --dh none \
    --push "redirect-gateway def1" --keepalive 5 15 --duplicate-cn --verb 3' >/dev/null

# Back to the proxy: its line first, beside the OpenVPN one the pin names, as
# vpn refuses a list with no OpenVPN line; then no pin, which the proxy now
# passes the health check for; then the profile off, then the proxy's line
# alone.
restore() {
  kill "${watcher:-}" 2>/dev/null || true
  sudo docker rm -f dotdash-rig-ovpnclient >/dev/null 2>&1 || true
  sudo docker start dotdash-rig-upstream dotdash-rig-ovpn >/dev/null 2>&1 || true
  list "${one}" "${good:-} name=vpn" || true
  # On the way out after a pass, vpn is gone already.
  [ -z "$(service_container vpn 2>/dev/null)" ] || settled || true
  sudo morzer config set upstream_pin=none >/dev/null 2>&1 || true
  sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true
  list "${one}" || true
  sudo docker rm -f dotdash-rig-ovpn >/dev/null 2>&1 || true
}
trap restore EXIT

# A REALITY client of this hook's own, from the links as they are now:
# 45-revocation.sh rotates reality_key, which locks 10-clients.sh's out.
xray_client=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
link=$(sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality.*type=tcp') ||
  die "client-config printed no REALITY link"
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
rest=${link#vless://}
mkdir -p /rig/clients/ovpnclient
jq -n --arg id "${rest%%@*}" --arg enc "$(param "${link}" encryption)" --arg sni "$(param "${link}" sni)" \
  --arg pbk "$(param "${link}" pbk)" --arg sid "$(param "${link}" sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11097, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' \
  >/rig/clients/ovpnclient/client.json
chmod -R a+rX /rig/clients/ovpnclient
sudo docker rm -f dotdash-rig-ovpnclient >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-ovpnclient --network host -v /rig/clients/ovpnclient:/etc/xray:ro "${xray_client}" >/dev/null

body() { # <url>: through this hook's REALITY client; the body, or nothing
  curl -s --max-time 20 --retry 2 --retry-delay 2 --socks5-hostname 127.0.0.1:11097 "$1" 2>/dev/null || true
}
doctor() { { sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' '; }
# The tunnel's containers, watched while an apply runs: a failed one rolls
# back and removes them before the diagnose step looks. watch_tunnel starts
# it, tunnel_logs stops it and prints what was seen, with the stand-in's log.
watch_tunnel() {
  (
    while :; do
      for svc in vpn vpn-socks; do
        c=$(sudo docker ps -aq --filter "label=com.docker.compose.service=${svc}" | sed -n 1p)
        [ -n "${c}" ] || continue
        {
          sudo docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} {{.State.Error}} health={{if .State.Health}}{{.State.Health.Status}} {{range .State.Health.Log}}[{{.ExitCode}}: {{.Output}}]{{end}}{{end}}' "${c}"
          sudo docker logs --tail 25 "${c}" 2>&1 | grep -vE 'Note:|library versions'
        } >"${pki}/${svc}.seen" 2>&1 || true
      done
      sleep 3
    done
  ) &
  watcher=$!
}
tunnel_logs() {
  kill "${watcher}" 2>/dev/null || true
  local f
  for f in "${pki}"/vpn.seen "${pki}"/vpn-socks.seen; do
    [ -e "${f}" ] && { echo "--- ${f##*/}" >&2; cat "${f}" >&2; }
  done
  echo "--- the stand-in server" >&2
  sudo docker logs --tail 15 dotdash-rig-ovpn 2>&1 | grep -vE 'Note:|library versions' >&2 || true
}
# Up to 30 s: secret set returns once the gate restarts, before it serves,
# and curl does not retry a refused connection.
reaches() { # <url>: whether a client gets the target's "ok"
  local _
  for _ in $(seq 15); do [ "$(body "$1")" = ok ] && return 0; sleep 2; done
  return 1
}

client_config() { # [verb] [server]: the client's config, inline keys
  printf 'client\ndev tun\nproto udp\nremote %s 1194\nnobind\nremote-cert-tls server\nverb %s\n' "${2:-${host}}" "${1:-3}"
  printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' \
    "$(cat "${pki}/ca.crt")" "$(cat "${pki}/client.crt")" "$(cat "${pki}/client.key")"
}

started() { sudo docker inspect -f '{{.State.StartedAt}}' "$(service_container "$1")"; }
# By the processes' namespaces, from here: Xray's image has no shell.
netns() { sudo readlink "/proc/$(sudo docker inspect -f '{{.State.Pid}}' "$(service_container "$1")")/ns/net"; }
# Until vpn is healthy and vpn-socks runs in its namespace, and Xray is
# healthy, up to 120 s. An apply re-creates the gate with `up --wait`, which
# waits on Xray too, whose healthcheck fetches through the upstreams, every
# 30 s: after the outages above it is unhealthy for a while, and the apply,
# and its rollback, fail to start services.
settled() {
  local _
  for _ in $(seq 60); do
    [ "$(sudo docker inspect -f '{{.State.Health.Status}}' "$(service_container xray 2>/dev/null)" 2>/dev/null)" = healthy ] &&
      [ "$(sudo docker inspect -f '{{.State.Health.Status}}' "$(service_container vpn 2>/dev/null)" 2>/dev/null)" = healthy ] &&
      [ "$(sudo docker inspect -f '{{.State.Running}}' "$(service_container vpn-socks 2>/dev/null)" 2>/dev/null)" = true ] &&
      [ "$(netns vpn 2>/dev/null)" = "$(netns vpn-socks 2>/dev/null)" ] && return 0
    sleep 2
  done
  return 1
}

# Each config's line, from the task: openvpn:// and the config, gzipped.
line_of() { # <file>
  sudo morzer task run openvpn-line --output --input "conf=$1" | tail -n1
}
client_config >"${pki}/good.ovpn"
client_config 4 >"${pki}/good4.ovpn"
# A server where nothing answers, so its tunnel never comes up.
client_config 3 192.0.2.1 >"${pki}/dead.ovpn"
good=$(line_of "${pki}/good.ovpn") good4=$(line_of "${pki}/good4.ovpn") dead=$(line_of "${pki}/dead.ovpn")
case ${good} in openvpn://H4sI*) ;; *) die "openvpn-line did not print an openvpn:// line" ;; esac

# The gate knows the openvpn alias with the profile off, so the line comes
# first, leading nowhere, and the proxy carries the traffic.
list "${one}" "${good} name=vpn" || die "could not add an OpenVPN line with the profile off"
reaches "${target}" || die "the proxy stopped carrying traffic once an OpenVPN line was added"
echo "${0##*/}: openvpn-line's line, added with the profile off, leaves the proxy carrying traffic"

# The profile on: vpn starts with the line while the gate still dials the
# proxy. Then a dead tunnel before the live one, which the pin puts first, so
# the gate dials vpn:1081 and the live tunnel is tun1.
watch_tunnel
sudo morzer config set installation.profile=xdns,openvpn >/dev/null ||
  { tunnel_logs; die "could not turn on the openvpn profile with the proxy still the upstream"; }
reaches "${target}" || die "the proxy stopped carrying traffic once the openvpn profile was on"
list "${one}" "${dead} name=dead" "${good} name=vpn" || { tunnel_logs; die "could not list two OpenVPN lines"; }
settled || { tunnel_logs; die "vpn and vpn-socks did not settle after the list changed"; }
sudo morzer config set upstream_pin=vpn >/dev/null || { tunnel_logs; die "could not pin the live OpenVPN line"; }
# Only now is the proxy stopped, so nothing can leave through it.
sudo docker stop dotdash-rig-upstream >/dev/null
list "${dead} name=dead" "${good} name=vpn" || { tunnel_logs; die "could not switch the list to the OpenVPN lines"; }
reaches "${target}" || { tunnel_logs; die "a client does not reach the target through the second OpenVPN line"; }
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the OpenVPN server answering: $(doctor)"
health=$(sudo docker exec "$(service_container vpn)" /usr/local/bin/openvpn-entrypoint healthcheck 2>&1 || true)
[ "${health}" = "healthy: up: tun1; down: tun0" ] || die "vpn does not report the live tunnel up and the dead one down: ${health}"
route=$(sudo docker exec "$(service_container vpn)" ip -4 route show default || true)
[ -z "${route}" ] || die "vpn has a default route: ${route}"
kill "${watcher}" 2>/dev/null || true
echo "${0##*/}: with the proxy stopped, the second OpenVPN line carries a client through tun1, beside a dead tun0"

sudo docker stop dotdash-rig-ovpn >/dev/null
[ -z "$(body "${target}")" ] || die "a client got through with the OpenVPN server stopped"
out=$(doctor)
# doctor cuts a long message short, so the second line's verdict may be too.
if ! grep -qF 'vpn (OpenVPN, tun1)' <<<"${out}" || ! grep -qF 'dead (OpenVPN, tun0): the tunnel is down' <<<"${out}"; then
  die "doctor does not name each OpenVPN line by its tunnel with the server stopped: ${out}"
fi
sudo docker start dotdash-rig-ovpn >/dev/null
echo "${0##*/}: with the server stopped, nothing gets through, and doctor names each line's tunnel"


# A new list while OpenVPN runs takes effect when set: secret set restarts
# vpn, and Compose restarts vpn-socks after it, into vpn's new network
# namespace. The live line moves to tun0.
vpn_started=$(started vpn)
socks_started=$(started vpn-socks)
watch_tunnel
list "${good4} name=vpn" "${dead} name=dead" || { tunnel_logs; die "changing the OpenVPN lines while OpenVPN runs failed"; }
[ "$(started vpn)" != "${vpn_started}" ] || die "vpn did not restart when the list changed"
[ "$(started vpn-socks)" != "${socks_started}" ] || die "vpn-socks did not restart when the list changed"
[ "$(netns vpn)" = "$(netns vpn-socks)" ] || die "vpn-socks is not in vpn's network namespace after the restart"
reaches "${target}" || { tunnel_logs; die "a client does not reach the target after the list changed"; }
route=$(sudo docker exec "$(service_container vpn)" ip -4 route show default || true)
[ -z "${route}" ] || die "vpn has a default route after its restart: ${route}"
kill "${watcher}" 2>/dev/null || true
echo "${0##*/}: a new list while OpenVPN runs restarts vpn, vpn-socks joins it again, and a client gets through"

# openvpn dies inside vpn, as a crash or an OOM kill would end it: the image
# starts each again in place, so vpn's namespace, and vpn-socks in it, stay
# as they are.
vpn_started=$(started vpn)
socks_netns=$(netns vpn-socks)
watch_tunnel
sudo docker exec "$(service_container vpn)" pkill -KILL -x openvpn ||
  die "could not kill openvpn inside vpn"
reaches "${target}" || { tunnel_logs; die "a client does not reach the target after openvpn died inside vpn"; }
[ "$(started vpn)" = "${vpn_started}" ] || die "vpn restarted when openvpn died inside it"
[ "$(netns vpn-socks)" = "${socks_netns}" ] && [ "$(netns vpn)" = "${socks_netns}" ] ||
  die "vpn and vpn-socks no longer share the namespace after openvpn died"
sudo docker logs "$(service_container vpn)" 2>&1 | grep -c 'openvpn on tun0 (line 1) exited with' >/dev/null ||
  die "vpn's log does not show tun0's openvpn exiting and starting again"
kill "${watcher}" 2>/dev/null || true
echo "${0##*/}: openvpn killed inside vpn starts again in place, and a client gets through"

sudo docker start dotdash-rig-upstream >/dev/null
list "${one}" "${good} name=vpn" || die "could not put the proxy's line back first"
settled || { tunnel_logs; die "vpn and vpn-socks did not settle after the proxy's line came back"; }
if ! out=$(sudo morzer config set upstream_pin=none --verbose 2>&1); then
  echo "--- containers" >&2
  sudo docker ps -a --filter label=com.docker.compose.project=dotdash \
    --format '{{.Label "com.docker.compose.service"}} {{.Status}} {{.ID}} net={{.Networks}}' >&2 || true
  sudo docker inspect -f '{{.Name}} netmode={{.HostConfig.NetworkMode}}' "$(service_container vpn-socks)" >&2 || true
  die "could not drop the pin: $(grep -iE 'error|cannot|failed|conflict|denied' <<<"${out}" | tail -n 12)"
fi
reaches "${target}" || die "a client does not reach the target back on the proxy, with the profile still on"
sudo morzer config set installation.profile=xdns >/dev/null || die "could not drop the openvpn profile"
list "${one}" || die "could not switch back to the proxy's line alone"
reaches "${target}" || die "a client does not reach the target back on the proxy"
[ -z "$(service_container vpn 2>/dev/null || true)" ] || die "vpn still runs after the openvpn profile was dropped"
echo "${0##*/}: the proxy's line, then the xdns profile, go back to the proxy"
