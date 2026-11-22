#!/usr/bin/env bash
# A relay through another relay (via): with the stand-in server stopped, the
# relay still gets out, through a stand-in for another relay that lets its
# dotdash_id in on 443, as a relay lets devices in, and logs what it carries.
# The stand-in sits on the relay's own network, where its name resolves: 443
# on the rig is the relay's. Two lines render an outbound each behind a
# balancer; a short line, and via with dotdash_link=xhttp-reality, are refused
# in the plan. Then the relay is back on the stand-in server.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  via:' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates via"
  exit 0
fi

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
[ -n "${xray}" ] || die "the bundle's pinned xray image is not in the rig"
keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
sid=$(openssl rand -hex 8)
id=$(sudo cat /run/dotdash-relay/secrets/dotdash_id)

mkdir -p /rig/relay/middle
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" '
  {log: {loglevel: "warning"},
   inbounds: [{listen: "0.0.0.0", port: 443, protocol: "vless",
     settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}}],
   outbounds: [{protocol: "freedom"}]}' >/rig/relay/middle/config.json
chmod -R a+rX /rig/relay/middle
sudo docker rm -f relay-rig-middle >/dev/null 2>&1 || true
sudo docker run -d --name relay-rig-middle --network dotdash-relay_default \
  -v /rig/relay/middle:/etc/xray:ro "${xray}" >/dev/null

line="relay-rig-middle www.gstatic.com ${public} ${sid} none"
printf '# the other relays\n%s own-site 0123 name=mid\nb.invalid b.invalid %s %s none\n' "${line}" "${public}" "${sid}" \
  >/rig/relay/via-two
plan=$(sudo morzer config set --set-file via=/rig/relay/via-two --dry-run 2>&1) || die "could not plan two via lines: ${plan}"
for want in '"address": "relay-rig-middle", "port": 443' '"address": "b.invalid", "port": 443' \
  "\"password\": \"${public}\", \"shortId\": \"${sid}\"" '"balancerTag": "dotdash"'; do
  grep -qF -- "${want}" <<<"${plan}" || die "the plan for two via lines renders no ${want}: $(tail -n 40 <<<"${plan}")"
done
printf 'a.invalid a.invalid %s %s\n' "${public}" "${sid}" >/rig/relay/via-short
out=$(sudo morzer config set --set-file via=/rig/relay/via-short --dry-run 2>&1) && die "a via line of four fields was taken"
grep -qF "a via line is <host> <site>" <<<"${out}" || die "a short via line was refused without saying why: ${out}"
echo "${0##*/}: two via lines render an outbound each behind a balancer; a short one is refused"

sudo docker stop relay-rig-server >/dev/null
printf '%s\n' "${line}" >/rig/relay/via-one
sudo morzer config set --set-file via=/rig/relay/via-one >/dev/null ||
  die "with the server stopped, the relay did not get out through the other relay: the apply's health check failed"
sudo jq -e '(.outbounds | length) == 1 and .outbounds[0].settings.address == "relay-rig-middle" and (.routing == null)' \
  /etc/dotdash-relay/xray.json >/dev/null || die "one via line renders a balancer or another way out"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails through the other relay"
out=$(sudo morzer config set dotdash_link=xhttp-reality --dry-run 2>&1) && die "via took dotdash_link=xhttp-reality"
grep -qF "not through via" <<<"${out}" || die "xhttp-reality with via was refused without saying why: ${out}"
echo "${0##*/}: with the server stopped, the relay gets out through the other relay"

sudo docker start relay-rig-server >/dev/null
printf '# none\n' >/rig/relay/via-none
sudo morzer config set --set-file via=/rig/relay/via-none >/dev/null || die "could not empty via"
sudo docker rm -f relay-rig-middle >/dev/null
for _ in $(seq 15); do
  sudo morzer doctor >/dev/null 2>&1 && break
  sleep 2
done
out=$(sudo morzer doctor 2>&1) || die "back on the stand-in server, the relay does not get out: ${out}"
echo "${0##*/}: with via empty, the relay is back on the server"
