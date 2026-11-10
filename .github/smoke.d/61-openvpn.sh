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
# - one config set goes back to the proxy and the xdns profile CI installs.
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
  sudo docker start dotdash-rig-upstream >/dev/null 2>&1 || true
  sudo morzer config set installation.profile=xdns upstream_protocol=http >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-ovpn >/dev/null 2>&1 || true
}
trap restore EXIT

body() { # <url>: through 10-clients.sh's REALITY client; the body, or nothing
  curl -s --max-time 20 --retry 2 --retry-delay 2 --socks5-hostname 127.0.0.1:11080 "$1" 2>/dev/null || true
}
doctor() { { sudo morzer doctor 2>&1 || true; } | tr -s ' \n' ' '; }
# Up to 30 s: secret set returns once the gate restarts, before it serves,
# and curl does not retry a refused connection.
reaches() { # <url>: whether a client gets the target's "ok"
  local _
  for _ in $(seq 15); do [ "$(body "$1")" = ok ] && return 0; sleep 2; done
  return 1
}

{
  printf 'client\ndev tun\nproto udp\nremote %s 1194\nnobind\nremote-cert-tls server\nverb 3\n' "${host}"
  printf '<ca>\n%s\n</ca>\n<cert>\n%s\n</cert>\n<key>\n%s\n</key>\n' \
    "$(cat "${pki}/ca.crt")" "$(cat "${pki}/client.crt")" "$(cat "${pki}/client.key")"
} | sudo morzer secret set upstream_openvpn >/dev/null ||
  die "setting upstream_openvpn while the proxy is the upstream failed"
reaches "${target}" || die "the proxy stopped carrying traffic once upstream_openvpn was set"
echo "${0##*/}: upstream_openvpn set, and the proxy still the upstream"

sudo docker stop dotdash-rig-upstream >/dev/null
sudo morzer config set installation.profile=xdns,openvpn upstream_protocol=openvpn >/dev/null ||
  die "could not switch to the OpenVPN upstream (its health check failed?)"
reaches "${target}" || die "a client does not reach the target through the OpenVPN upstream"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the OpenVPN server answering: $(doctor)"
route=$(sudo docker exec "$(service_container vpn)" ip -4 route show default || true)
case ${route} in '' | *" dev tun"*) ;; *) die "vpn has a default route around the tunnel: ${route}" ;; esac
echo "${0##*/}: with the proxy stopped, the OpenVPN upstream carries the health check and a client"

sudo docker stop dotdash-rig-ovpn >/dev/null
[ -z "$(body "${target}")" ] || die "a client got through with the OpenVPN server stopped"
grep -q 'the OpenVPN tunnel is' <<<"$(doctor)" || die "doctor does not name the OpenVPN tunnel with its server stopped"
sudo docker start dotdash-rig-ovpn >/dev/null
echo "${0##*/}: with the server stopped, nothing gets through, and doctor names the tunnel"

sudo docker start dotdash-rig-upstream >/dev/null
sudo morzer config set installation.profile=xdns upstream_protocol=http >/dev/null ||
  die "could not switch back to the proxy"
reaches "${target}" || die "a client does not reach the target back on the proxy"
[ -z "$(service_container vpn 2>/dev/null || true)" ] || die "vpn still runs after the openvpn profile was dropped"
echo "${0##*/}: one config set goes back to the proxy and the xdns profile"
