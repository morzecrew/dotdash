#!/usr/bin/env bash
# The hysteria2 profile, beside own-site: the relay serves Hysteria2 on
# hysteria2_port (443/udp) under its own site's certificate, and carries it on
# to dotdash like REALITY. With the relay's domain and Caddy's own CA
# (cert_issuer=internal), as 25-own-site.sh has them:
#
# - hysteria2 without own-site is refused: it has no certificate to serve;
# - under own-site,hysteria2, relay-entry ends the line with hy2=443, says how
#   a canary checks it, and the facts carry the port;
# - a listed device logging in with its id, trusting the site's CA, gets out
#   through the relay and the stand-in server; one with another login does not;
# - dropping the profile shuts the port, and the line loses the field.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

domain=relay.test
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
restore() {
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-hy2 relay-rig-hy2-wrong >/dev/null 2>&1 || true
}
trap restore EXIT

# Captured, then read: a reader that stops early would kill the task's output.
entry() { local out; out=$(sudo morzer task run relay-entry --output -- 127.0.0.1); grep -m1 '^relay/1 ' <<<"${out}" || true; }
ca_dir=/rig/relay/hy2-ca
device() { # <name> <port> <login>: a Hysteria2 client of the relay, HTTP proxy on 127.0.0.1:<port>
  mkdir -p "/rig/relay/$1"
  jq -n --arg auth "$3" --arg sni "${domain}" --argjson port "$2" '
    {inbounds: [{listen: "127.0.0.1", port: $port, protocol: "http"}],
     outbounds: [{protocol: "hysteria", settings: {version: 2, address: "127.0.0.1", port: 443},
       streamSettings: {network: "hysteria", security: "tls",
         tlsSettings: {serverName: $sni, alpn: ["h3"],
           certificates: [{usage: "verify", certificateFile: "/ca/root.crt"}]},
         hysteriaSettings: {version: 2, auth: $auth},
         finalmask: {quicParams: {keepAlivePeriod: 10}}}}]}' >"/rig/relay/$1/config.json"
  chmod -R a+rX "/rig/relay/$1"
  sudo docker rm -f "relay-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "relay-rig-$1" --network host -v "/rig/relay/$1:/etc/xray:ro" -v "${ca_dir}:/ca:ro" "${xray}" >/dev/null
}
status() { # <port> [retries]: probe_url's status through that device, or 000
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry "${2:-10}" --retry-delay 3 --retry-all-errors \
    --proxy "http://127.0.0.1:$1" https://www.gstatic.com/generate_204 || true
}

set_config "installation.domains=${domain}"
set_config cert_issuer=internal
! sudo morzer config set installation.profile=hysteria2 >/dev/null 2>&1 ||
  die "the hysteria2 profile was taken without own-site, whose certificate it serves"
[[ $(entry) != *hy2=* ]] || die "relay-entry prints a hy2= field without the hysteria2 profile"
set_config installation.profile=own-site,hysteria2

[[ $(entry) == *" hy2=443"* ]] || die "relay-entry printed no hy2=443 under own-site,hysteria2"
out=$(sudo morzer task run relay-entry --output -- 127.0.0.1)
grep -qxF 'sudo morzer config set installation.profile=hysteria2 dotdash_hysteria2_port=443' <<<"${out}" ||
  die "relay-entry does not say how a canary checks the relay's Hysteria2"
facts=$(sudo morzer task run facts --output 2>/dev/null)
jq -e '.hysteria2 == {port: 443}' <<<"${facts}" >/dev/null || die "the facts do not carry the Hysteria2 port"
echo "${0##*/}: hysteria2 needs own-site; under both, relay-entry and the facts carry hy2=443"

# The site's CA: Caddy's own, under cert_issuer=internal, from its data.
data=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash-relay_caddy_data)
sudo mkdir -p "${ca_dir}"
for _ in $(seq 30); do sudo test -f "${data}/caddy/pki/authorities/local/root.crt" && break; sleep 2; done
sudo cp "${data}/caddy/pki/authorities/local/root.crt" "${ca_dir}/root.crt" || die "Caddy made no CA of its own"
sudo chmod -R a+rX "${ca_dir}"

device hy2 18095 "$(cat /rig/relay/device)"
code=$(status 18095)
[ "${code}" = 204 ] || die "a listed device got ${code} over Hysteria2 through the relay, not 204"
device hy2-wrong 18096 "$(cat /proc/sys/kernel/random/uuid)"
code=$(status 18096 0)
[ "${code}" != 204 ] || die "a device with another login got through the relay's Hysteria2"
echo "${0##*/}: a listed device gets out over Hysteria2 through the relay; another login does not"

set_config installation.profile=own-site
[[ $(entry) != *hy2=* ]] || die "relay-entry still prints a hy2= field after dropping the profile"
code=$(status 18095 0)
[ "${code}" != 204 ] || die "Hysteria2 still gets through the relay after dropping the profile"
echo "${0##*/}: dropping the profile shuts Hysteria2 and its field"
