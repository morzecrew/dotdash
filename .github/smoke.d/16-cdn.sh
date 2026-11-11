#!/usr/bin/env bash
# Domestic CDNs (cdn_hosts): client-config adds a link per CDN and an outbound
# in the Xray config, shaped for CDNs that pass GET alone and no request body:
# XHTTP packet-up, uploads in GET requests with the data in headers. The rig
# has no CDN, so the server stands in for one under its own name:
#
# - the link has that shape;
# - a client built from the config's CDN outbound, pointed at the server, gets
#   through, so the server reads uploads placed so, and the outbound works;
# - so does one for a CDN under a name of its own, sent as SNI and Host, as a
#   CDN on its defaults sends it: the server's site answers under any name;
# - with cdn_hosts back to none, no CDN link is printed.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  cdn_hosts:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates cdn_hosts"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
dir=/rig/clients/cdn
restore() {
  sudo morzer config set cdn_hosts=none >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-cdn >/dev/null 2>&1 || true
}
trap restore EXIT

sudo morzer config set cdn_hosts=dotdash.test >/dev/null || die "could not set cdn_hosts"
out=$(sudo morzer task run client-config --output -- --full)
grep -qE '^vless://[^@]+@dotdash\.test:443\?.*&type=xhttp&.*&mode=packet-up&extra=%7B.*uplinkDataPlacement%22%3A%22header%22.*uplinkHTTPMethod%22%3A%22GET%22.*#.*%5Bcdn%20dotdash\.test%5D$' <<<"${out}" ||
  die "client-config printed no CDN link of packet-up, GET and header uploads"
echo "${0##*/}: a link through the CDN, uploading by GET with the data in headers"

config=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}")
outbound=$(jq -c 'first(.outbounds[] | select(.tag == "dotdash-cdn-1"))' <<<"${config}")
[ -n "${outbound}" ] || die "the Xray config has no CDN outbound"
jq -e '.streamSettings.xhttpSettings | .mode == "packet-up" and .uplinkHTTPMethod == "GET" and .uplinkDataPlacement == "header"' \
  <<<"${outbound}" >/dev/null || die "the CDN outbound does not upload by GET with the data in headers: ${outbound}"

# The outbound as printed, but dialling the server, which stands in for the CDN,
# and trusting the rig's CA, as 10-clients.sh's XHTTP client does.
mkdir -p "${dir}"
jq -n --argjson ob "${outbound}" '{inbounds: [{listen: "127.0.0.1", port: 11098, protocol: "socks"}],
  outbounds: [$ob | .settings.address = "127.0.0.1"
    | .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]]}' >"${dir}/client.json"
chmod -R a+rX "${dir}"
sudo docker rm -f dotdash-rig-cdn >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-cdn --network host -v "${dir}:/etc/xray:ro" \
  -v /rig/clients/root.pem:/ca/root.pem:ro "${xray}" >/dev/null
got=$(curl -fsS --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors \
  --socks5-hostname 127.0.0.1:11098 http://11.99.0.10:8000/ || true)
[ "${got}" = ok ] || { sudo docker logs dotdash-rig-cdn 2>&1 | tail -5 >&2; die "the CDN outbound did not get through the server"; }
echo "${0##*/}: the CDN outbound gets through, the server reading its GET uploads"

# A CDN on its defaults passes the device's name on as Host, and maybe as SNI:
# cdn.test, a name the server has no certificate for, gets this domain's
# (fallback_sni), which the client checks against dotdash.test, as a CDN
# that checks the origin does.
if sudo grep -q fallback_sni /opt/dotdash/current/caddy/Caddyfile; then
  sudo morzer config set cdn_hosts=cdn.test >/dev/null || die "could not set cdn_hosts"
  out=$(sudo morzer task run client-config --output -- --full)
  outbound=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}" |
    jq -c 'first(.outbounds[] | select(.tag == "dotdash-cdn-1"))')
  jq -e '.streamSettings | .tlsSettings.serverName == "cdn.test" and .xhttpSettings.host == "cdn.test"' \
    <<<"${outbound}" >/dev/null || die "the CDN outbound does not name cdn.test: ${outbound}"
  jq -n --argjson ob "${outbound}" '{inbounds: [{listen: "127.0.0.1", port: 11098, protocol: "socks"}],
    outbounds: [$ob | .settings.address = "127.0.0.1"
      | .streamSettings.tlsSettings.verifyPeerCertByName = "dotdash.test"
      | .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]]}' >"${dir}/client.json"
  sudo docker restart dotdash-rig-cdn >/dev/null
  got=$(curl -fsS --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors \
    --socks5-hostname 127.0.0.1:11098 http://11.99.0.10:8000/ || true)
  [ "${got}" = ok ] || { sudo docker logs dotdash-rig-cdn 2>&1 | tail -5 >&2; die "a CDN under a name of its own did not get through"; }
  echo "${0##*/}: a CDN sending its own name as SNI and Host gets through, the site answering under any name"
fi

sudo morzer config set cdn_hosts=none >/dev/null || die "could not unset cdn_hosts"
! sudo morzer task run client-config --output -- --full | grep -q '%5Bcdn%20' ||
  die "a CDN link is still printed with cdn_hosts=none"
sudo docker rm -f dotdash-rig-cdn >/dev/null
echo "${0##*/}: with cdn_hosts=none, no CDN link"
