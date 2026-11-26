#!/usr/bin/env bash
# The CDN checks: facts checks each CDN in front of a relay through it, as
# devices' CDN links go, and gives each by name under cdn. The CDN stand-in
# is Caddy, under a certificate of its own for cdn.test, door.test and
# gw.door.test, on the canary's network, where those names are its. It passes
# cdn.test on to an Xray standing in for a relay's CDN inbound, disguised on
# the CDN path, and the door's names to a plain XHTTP inbound on that path,
# where a relay's door sends them; gw.door.test gives that path as its own
# (<name>/<path>). Each gets through while the stand-in answers, carrying the
# disguise's X-Part uploads to cdn.test, and none once it stops, with REALITY
# up all along: the checks go through the CDN. No public CA signed the
# stand-in's certificate, so the rendered reality.json gets it to verify by,
# as the relay smoke's devices do, and the reality service restarts on it;
# facts renders that file again but restarts nothing.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  dotdash_cdn_hosts:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
[ -n "${xray}" ] || die "the bundle's pinned xray image is not in the rig"
# The servers' and relays' Caddy, as their manifests pin it.
caddy=ghcr.io/morzecrew/caddy-acmedns:2.11.9@sha256:93c19f705c2218d5fca7f7dcb694cae1ed3889588678aabb7af34c8892e2f2bb
id=$(sudo jq -r '.inbounds[0].settings.clients[0].id' /rig/server/config.json)
path=$(openssl rand -hex 12)
network=$(sudo docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(service_container reality)")

restore() {
  sudo docker rm -f canary-rig-cdn canary-rig-cdn-origin >/dev/null 2>&1 || true
  sudo morzer config unset dotdash_cdn_hosts >/dev/null 2>&1 || true
  sudo morzer config unset dotdash_origin_host >/dev/null 2>&1 || true
}
trap restore EXIT

facts() {
  local out
  out=$(sudo morzer task run facts --output 2>&1) || die "facts failed: ${out}"
  grep -m1 '^{' <<<"${out}"
}

mkdir -p /rig/cdn /rig/cdn-origin
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj /CN=cdn.test \
  -addext subjectAltName=DNS:cdn.test,DNS:door.test,DNS:gw.door.test -keyout /rig/cdn/cdn.key -out /rig/cdn/cdn.crt 2>/dev/null
cat >/rig/cdn/Caddyfile <<'EOF'
{
	admin off
	auto_https disable_redirects
}
(stand-in) {
	tls /cdn/cdn.crt /cdn/cdn.key
	log {
		output stdout
		format json
	}
}
cdn.test {
	import stand-in
	reverse_proxy 127.0.0.1:8082
}
door.test, gw.door.test {
	import stand-in
	reverse_proxy 127.0.0.1:8083
}
EOF
# The relay's CDN inbound (its xray.json.tmpl's devices-cdn) on 8082, and on
# 8083 the plain XHTTP inbound its door passes the CDN path on to.
jq -n --arg id "${id}" --arg path "/${path}" '
  {inbounds: [
    {listen: "127.0.0.1", port: 8082, protocol: "vless", settings: {clients: [{id: $id}], decryption: "none"},
     streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "packet-up",
       xPaddingBytes: "64-256", xPaddingObfsMode: true, xPaddingMethod: "tokenish",
       xPaddingPlacement: "cookie", xPaddingKey: "csrftoken", sessionIDPlacement: "cookie", sessionIDKey: "sessionid",
       seqPlacement: "cookie", seqKey: "seq", uplinkDataKey: "X-Part", noSSEHeader: true}}},
    {listen: "127.0.0.1", port: 8083, protocol: "vless", settings: {clients: [{id: $id}], decryption: "none"},
     streamSettings: {network: "xhttp", xhttpSettings: {path: $path, mode: "auto"}}}],
   outbounds: [{protocol: "freedom"}]}' >/rig/cdn-origin/config.json
chmod -R a+rX /rig/cdn /rig/cdn-origin
sudo docker run -d --name canary-rig-cdn --network "${network}" \
  --network-alias cdn.test --network-alias door.test --network-alias gw.door.test \
  --sysctl net.ipv4.ip_unprivileged_port_start=0 -v /rig/cdn:/cdn:ro "${caddy}" \
  caddy run --config /cdn/Caddyfile --adapter caddyfile >/dev/null
sudo docker run -d --name canary-rig-cdn-origin --network container:canary-rig-cdn \
  -v /rig/cdn-origin:/etc/xray:ro "${xray}" >/dev/null

printf %s "${path}" | sudo morzer secret set dotdash_cdn_xhttp_path >/dev/null
sudo morzer config set dotdash_cdn_hosts=cdn.test "dotdash_origin_host=door.test,gw.door.test/${path}" >/dev/null ||
  die "could not set the CDN names"
jq --rawfile pem /rig/cdn/cdn.crt '.outbounds |= map(if (.tag | test("^dotdash-(cdn|door)-")) then
    .streamSettings.tlsSettings.certificates = [{usage: "verify", certificate: ($pem | rtrimstr("\n") | split("\n"))}]
  else . end)' /etc/dotdash-canary/reality.json >/rig/cdn/reality.json
[ "$(jq '[.outbounds[] | select(.streamSettings.tlsSettings.certificates)] | length' /rig/cdn/reality.json)" = 3 ] ||
  die "the rendered reality.json has no outbound for each of the 3 CDN names: $(jq -c '[.outbounds[].tag]' /rig/cdn/reality.json)"
sudo tee /etc/dotdash-canary/reality.json </rig/cdn/reality.json >/dev/null
sudo docker restart "$(service_container reality)" >/dev/null

got=$(facts)
jq -e '.paths.reality == true and .cdn == {"cdn.test": true, "door.test": true, "gw.door.test": true}' <<<"${got}" >/dev/null ||
  die "facts with the CDN stand-in up: ${got}"
# The disguise, as a CDN's log shows it: one path, the session in a cookie,
# the upload in X-Part headers.
log=$(sudo docker logs canary-rig-cdn 2>&1)
grep -qE "\"host\":\"cdn\\.test\",\"uri\":\"/${path}\",.*\"X-Part-0\"" <<<"${log}" ||
  die "no request to cdn.test on the bare CDN path carried an X-Part upload: $(grep -F '"host":"cdn.test"' <<<"${log}" | tail -n 1 | cut -c1-600)"
echo "${0##*/}: each CDN name gets through the stand-in: $(jq -c .cdn <<<"${got}")"

sudo docker stop canary-rig-cdn >/dev/null
got=$(facts)
jq -e '.paths.reality == true and .cdn == {"cdn.test": false, "door.test": false, "gw.door.test": false}' <<<"${got}" >/dev/null ||
  die "facts with the CDN stand-in stopped: ${got}"
echo "${0##*/}: with the stand-in stopped, no CDN name gets through and REALITY still does"
