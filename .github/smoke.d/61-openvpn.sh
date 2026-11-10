#!/usr/bin/env bash
# An OpenVPN upstream (upstream_protocol=openvpn, the openvpn profile): an
# OpenVPN client (vpn) and a SOCKS hop in its namespace (vpn-socks), which the
# gate dials. A stand-in server, the bundle's openvpn image in server mode,
# carries the rig's traffic on to the target, with the rig's HTTP proxy
# stopped so nothing can leave through it:
#
# - setting upstream_openvpn changes nothing while the proxy is the upstream;
# - with the profile and upstream_protocol=openvpn, apply's health check
#   passes through the tunnel, a client reaches the target, doctor passes,
#   and vpn has no default route around the tunnel;
# - with the server stopped, nothing gets through, and doctor names the
#   OpenVPN tunnel;
# - a new config while OpenVPN runs restarts vpn and vpn-socks, and traffic
#   flows again;
# - upstream_protocol=http, then the xdns profile CI installs, go back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  - name: upstream_openvpn$' /opt/dotdash/current/secrets.schema.yaml; then
  echo "${0##*/}: skipped, the installed release predates the OpenVPN upstream"
  exit 0
fi

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
    --push "redirect-gateway def1" --keepalive 5 15 --verb 3' >/dev/null

restore() {
  kill "${watcher:-}" 2>/dev/null || true
  sudo docker rm -f dotdash-rig-ovpnclient >/dev/null 2>&1 || true
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo morzer config set upstream_protocol=http >/dev/null 2>&1 || true
  sudo morzer config set installation.profile=xdns >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-ovpn >/dev/null 2>&1 || true
}
trap restore EXIT

# A REALITY client of this hook's own, from the links as they are now:
# 45-revocation.sh rotates reality_key, which locks 10-clients.sh's out.
xray_client=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
link=$(sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality') ||
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

client_config() { # [verb]: the client's config, inline keys
  printf 'client\ndev tun\nproto udp\nremote %s 1194\nnobind\nremote-cert-tls server\nverb %s\n' "${host}" "${1:-3}"
  printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' \
    "$(cat "${pki}/ca.crt")" "$(cat "${pki}/client.crt")" "$(cat "${pki}/client.key")"
}

# morzer restarts neither vpn nor vpn-socks, the secret's services, while the
# profile is off (0.15.1), so this succeeds.
client_config | sudo morzer secret set upstream_openvpn >/dev/null ||
  die "setting upstream_openvpn while the proxy is the upstream failed"
reaches "${target}" || die "the proxy stopped carrying traffic once upstream_openvpn was set"
echo "${0##*/}: upstream_openvpn set, and the proxy still the upstream"

# A setting and a parameter are set apart, the profile first: vpn starts
# while the gate still dials the proxy, then the gate moves to it.
watch_tunnel
sudo morzer config set installation.profile=xdns,openvpn >/dev/null ||
  { tunnel_logs; die "could not turn on the openvpn profile with the proxy still the upstream"; }
reaches "${target}" || die "the proxy stopped carrying traffic once the openvpn profile was on"
# Only now is the proxy stopped, so nothing can leave through it: before the
# protocol moves, it is still the gate's upstream and Xray's egress check.
sudo docker stop dotdash-rig-upstream >/dev/null
sudo morzer config set upstream_protocol=openvpn >/dev/null ||
  { tunnel_logs; die "could not switch to the OpenVPN upstream (its health check failed?)"; }
reaches "${target}" || { tunnel_logs; die "a client does not reach the target through the OpenVPN upstream"; }
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the OpenVPN server answering: $(doctor)"
route=$(sudo docker exec "$(service_container vpn)" ip -4 route show default || true)
case ${route} in '' | *" dev tun"*) ;; *) die "vpn has a default route around the tunnel: ${route}" ;; esac
kill "${watcher}" 2>/dev/null || true
echo "${0##*/}: with the proxy stopped, the OpenVPN upstream carries the health check and a client"

sudo docker stop dotdash-rig-ovpn >/dev/null
[ -z "$(body "${target}")" ] || die "a client got through with the OpenVPN server stopped"
grep -q 'the OpenVPN tunnel is' <<<"$(doctor)" || die "doctor does not name the OpenVPN tunnel with its server stopped"
sudo docker start dotdash-rig-ovpn >/dev/null
echo "${0##*/}: with the server stopped, nothing gets through, and doctor names the tunnel"

# A new config while OpenVPN runs takes effect when set: secret set restarts
# vpn, and vpn-socks after it, into vpn's new network namespace.
started() { sudo docker inspect -f '{{.State.StartedAt}}' "$(service_container "$1")"; }
vpn_started=$(started vpn)
socks_started=$(started vpn-socks)
watch_tunnel
client_config 4 | sudo morzer secret set upstream_openvpn >/dev/null ||
  { tunnel_logs; die "changing upstream_openvpn while OpenVPN runs failed"; }
[ "$(started vpn)" != "${vpn_started}" ] || die "vpn did not restart when upstream_openvpn changed"
[ "$(started vpn-socks)" != "${socks_started}" ] || die "vpn-socks did not restart when upstream_openvpn changed"
reaches "${target}" || { tunnel_logs; die "a client does not reach the target after upstream_openvpn changed"; }
route=$(sudo docker exec "$(service_container vpn)" ip -4 route show default || true)
case ${route} in '' | *" dev tun"*) ;; *) die "vpn has a default route around the tunnel after its restart: ${route}" ;; esac
kill "${watcher}" 2>/dev/null || true
echo "${0##*/}: a new config while OpenVPN runs restarts vpn and vpn-socks, and a client gets through"

sudo docker start dotdash-rig-upstream >/dev/null
sudo morzer config set upstream_protocol=http >/dev/null || die "could not switch back to the proxy"
reaches "${target}" || die "a client does not reach the target back on the proxy, with the profile still on"
sudo morzer config set installation.profile=xdns >/dev/null || die "could not drop the openvpn profile"
reaches "${target}" || die "a client does not reach the target back on the proxy"
[ -z "$(service_container vpn 2>/dev/null || true)" ] || die "vpn still runs after the openvpn profile was dropped"
echo "${0##*/}: upstream_protocol=http, then the xdns profile, go back to the proxy"
