#!/usr/bin/env bash
# The server's CDN links take a path of their own (the cdn_xhttp_path secret),
# disguised as a relay's CDN path is: one path, the session, sequence and
# padding in cookies, the upload under X-Part. 16-cdn.sh already shows a
# client built from the CDN outbound getting through. Here:
#
# - the CDN link and outbound take the CDN path, not xhttp_path, disguised;
# - a client still shaped as the CDN links were before (xhttp_path, plain)
#   gets through a CDN name too, as configs imported by hand are.
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
dir=/rig/clients/cdn-path
restore() {
  sudo morzer config set cdn_hosts=none >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-cdn-path >/dev/null 2>&1 || true
}
trap restore EXIT

secrets=/run/dotdash/secrets
cdn_path=$(sudo cat "${secrets}/cdn_xhttp_path")
xhttp_path=$(sudo cat "${secrets}/xhttp_path")
[ "${#cdn_path}" = 24 ] || die "cdn_xhttp_path is not 24 hex characters"

sudo morzer config set cdn_hosts=cdn.test >/dev/null || die "could not set cdn_hosts"
out=$(sudo morzer task run client-config --output -- --full)
link=$(grep -m1 -E '^vless://[^@]+@cdn\.test:443\?.*#server%20%C2%B7%20cdn$' <<<"${out}") || die "no link through the CDN"
[[ ${link} == *"&path=%2F${cdn_path}&"* ]] || die "the CDN link does not take the CDN path"
[[ ${link} == *xPaddingObfsMode%22%3Atrue*sessionIDPlacement%22%3A%22cookie%22*seqPlacement%22%3A%22cookie%22* ]] ||
  die "the CDN link is not disguised"
outbound=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${out}" |
  jq -c 'first(.outbounds[] | select(.tag == "dotdash-cdn-1"))')
jq -e --arg p "/${cdn_path}" '.streamSettings.xhttpSettings | .path == $p and .xPaddingObfsMode == true
    and .xPaddingPlacement == "cookie" and .sessionIDPlacement == "cookie" and .uplinkDataKey == "X-Part"' \
  <<<"${outbound}" >/dev/null || die "the CDN outbound is not disguised on the CDN path"
echo "${0##*/}: the CDN link and outbound take the CDN path, disguised"

# The outbound as the CDN links were before, dialling the server as the CDN
# would, under the CDN's name, trusting the rig's CA (16-cdn.sh).
mkdir -p "${dir}"
jq -n --argjson ob "${outbound}" --arg p "/${xhttp_path}" '{inbounds: [{listen: "127.0.0.1", port: 11099, protocol: "socks"}],
  outbounds: [$ob | .settings.address = "127.0.0.1"
    | .streamSettings.xhttpSettings |= ({path: $p} + (with_entries(select(.key | IN("host", "mode", "uplinkHTTPMethod",
        "uplinkDataPlacement", "uplinkChunkSize", "scMaxEachPostBytes", "scMinPostsIntervalMs")))))
    | .streamSettings.tlsSettings.verifyPeerCertByName = "dotdash.test"
    | .streamSettings.tlsSettings.certificates = [{usage: "verify", certificateFile: "/ca/root.pem"}]]}' >"${dir}/client.json"
chmod -R a+rX "${dir}"
sudo docker rm -f dotdash-rig-cdn-path >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-cdn-path --network host -v "${dir}:/etc/xray:ro" \
  -v /rig/clients/root.pem:/ca/root.pem:ro "${xray}" >/dev/null
got=$(curl -fsS --max-time 30 --retry 5 --retry-delay 2 --retry-all-errors \
  --socks5-hostname 127.0.0.1:11099 http://11.99.0.10:8000/ || true)
[ "${got}" = ok ] || { sudo docker logs dotdash-rig-cdn-path 2>&1 | tail -5 >&2; die "a CDN client on xhttp_path, plain, did not get through"; }
echo "${0##*/}: a CDN client still on xhttp_path, plain, gets through"
