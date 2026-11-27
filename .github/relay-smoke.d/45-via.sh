#!/usr/bin/env bash
# A relay through another relay (the via secret, relay/1 lines): the relay's
# way to group s1 is then that relay alone. A stand-in for it, which lets
# this relay in by its id on s1, as s1's list for a real one would, and
# carries it on to s1's stand-in server, sits on the relay's own network,
# where its name resolves: 443 on the rig is the relay's. Through it the
# device gets out, and s1's list comes in; with it stopped, s1 is down, so
# the way goes through it alone. Two lines make a way each. A malformed
# line keeps Xray from starting, and health fails. Then via is empty, and
# the relay is back on the server.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
[ -n "${xray}" ] || die "the bundle's pinned xray image is not in the rig"
keys=$(sudo docker run --rm "${xray}" x25519)
private=$(sed -n 's/^PrivateKey: //p' <<<"${keys}")
public=$(sed -n 's/^Password (PublicKey): //p' <<<"${keys}")
[ -n "${private}" ] && [ -n "${public}" ] || die "xray x25519 printed no key pair: ${keys}"
sid=$(openssl rand -hex 8)
# shellcheck disable=SC2046 # one field per word
set -- $(cat /rig/relay/server-line)
spbk=$5 ssid=$6 id=$8 saddr=${10#address=}
restore() {
  printf '# none\n' | sudo morzer secret set via >/dev/null 2>&1 || true
  sudo morzer config unset via_link via_fingerprint >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-middle relay-rig-via >/dev/null 2>&1 || true
}
trap restore EXIT

mkdir -p /rig/relay/middle
jq -n --arg id "${id}" --arg key "${private}" --arg sid "${sid}" --arg spbk "${spbk}" --arg ssid "${ssid}" --arg saddr "${saddr}" '
  {log: {loglevel: "warning"},
   inbounds: [{listen: "0.0.0.0", port: 443, protocol: "vless",
     settings: {clients: [{id: $id, flow: "xtls-rprx-vision"}], decryption: "none"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {target: "www.gstatic.com:443", serverNames: ["www.gstatic.com"], privateKey: $key, shortIds: [$sid]}}}],
   outbounds: [{protocol: "vless",
     settings: {address: $saddr, port: 9443, id: $id, encryption: "none", flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality", realitySettings:
       {serverName: "www.gstatic.com", fingerprint: "chrome", password: $spbk, shortId: $ssid}}}]}' >/rig/relay/middle/config.json
chmod -R a+rX /rig/relay/middle
sudo docker rm -f relay-rig-middle >/dev/null 2>&1 || true
sudo docker run -d --name relay-rig-middle --network dotdash-relay_default \
  -v /rig/relay/middle:/etc/xray:ro "${xray}" >/dev/null

mkdir -p /rig/relay/via
jq '.inbounds[0].port = 18086' /rig/relay/phone/config.json >/rig/relay/via/config.json
chmod -R a+rX /rig/relay/via
sudo docker run -d --name relay-rig-via --network host -v /rig/relay/via:/etc/xray:ro "${xray}" >/dev/null
fetch() { # <retries>
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --retry "$1" --retry-delay 3 --retry-all-errors \
    --proxy http://127.0.0.1:18086 https://www.gstatic.com/generate_204 || true
}
servers() { sudo morzer task run servers --output 2>&1 || true; }
wait_for() { # <regex>: the servers task prints a matching line within 90 s
  for _ in $(seq 30); do
    out=$(servers)
    grep -Eq "$1" <<<"${out}" && return 0
    sleep 3
  done
  return 1
}

mid="relay/1 mid 0123456789abcdef relay-rig-middle www.gstatic.com ${public} ${sid} none"
printf '# the other relays\n%s\nrelay/1 far fedcba9876543210 b.invalid b.invalid %s %s none\n' "${mid}" "${public}" "${sid}" |
  sudo morzer secret set via >/dev/null || die "could not set two via lines"
wait_for '^s1 +live +relay-rig-middle ok [0-9]+ ms, b\.invalid down ' ||
  die "with two via lines, s1 is not live through the first with the second down: ${out}"
echo "${0##*/}: two via lines make a way each to s1, the one that answers serving its list"

printf '%s\n' "${mid}" | sudo morzer secret set via >/dev/null || die "could not set one via line"
wait_for '^s1 +live +relay-rig-middle ok [0-9]+ ms;' || die "with one via line, s1 is not live through it: ${out}"
[ "$(fetch 10)" = 204 ] || die "the device does not get out through the other relay"
sudo docker stop relay-rig-middle >/dev/null
wait_for '^s1 +down +relay-rig-middle down' || die "with the other relay stopped, s1 is not down: ${out}"
[ "$(fetch 0)" != 204 ] || die "with the other relay stopped, the device still got out: the way does not go through it alone"
sudo docker start relay-rig-middle >/dev/null
wait_for '^s1 +live +relay-rig-middle ok' || die "once the other relay is back, s1 is not live through it: ${out}"
[ "$(fetch 10)" = 204 ] || die "once the other relay is back, the device does not get out through it"
echo "${0##*/}: through the other relay alone, the device gets out and s1's list comes in"

# A via line Xray refuses keeps it from starting, which doctor says.
printf 'relay/1 short 0123456789abcdef a.invalid a.invalid\n' | sudo morzer secret set via >/dev/null 2>&1 || true
out=$(sudo morzer doctor 2>&1) || true
tr -s '[:space:]' ' ' <<<"${out}" | grep -qE 'a servers or via line it refuses|not running: xray' ||
  { printf '%s\n' "${mid}" | sudo morzer secret set via >/dev/null; die "doctor does not say Xray refuses a via line of six fields: ${out}"; }
printf '%s\n' "${mid}" | sudo morzer secret set via >/dev/null || die "could not put the via line back"
wait_for '^s1 +live +relay-rig-middle ok' || die "with the via line back, s1 is not live through the other relay: ${out}"
echo "${0##*/}: doctor says Xray refuses a malformed via line; the good line back, s1 is live through it again"

# via_link and via_fingerprint reach the gateway's config, as the image takes them.
plan=$(sudo morzer config set via_link=xhttp via_fingerprint=none --dry-run 2>&1) || die "could not plan via_link=xhttp: ${plan}"
grep -qF '"viaLink": "xhttp", "viaFingerprint": "none"' <<<"${plan}" ||
  die "the plan for via_link=xhttp via_fingerprint=none does not render them: $(tail -n 20 <<<"${plan}")"
echo "${0##*/}: via_link and via_fingerprint render into the gateway's config"

restore
trap - EXIT
wait_for '^s1 +live +www\.gstatic\.com ok' || die "with via empty, s1 is not back on its server: ${out}"
echo "${0##*/}: with via empty, the relay is back on the server"
