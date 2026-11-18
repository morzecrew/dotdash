#!/usr/bin/env bash
# Rotating the REALITY key with no device cut off (reality_second_key):
#
# 1. A next key beside the current one (second): devices on the current key
#    and on the next both get through, the next one by way of the public
#    inbound passing it on to its loopback twin; a key that is neither gets
#    nothing; links still carry the current key.
# 2. Swapped, the next key current and the old one second: both still get
#    through, and links now carry the next key.
# 3. reality_second_key off: the old key gets nothing, the new one through.
#
# Then the rig's own key is put back, for the scripts after this one. No link
# or key is printed.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  reality_second_key:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

target=http://11.99.0.10:8000/
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
secrets=/run/dotdash/secrets
param() { sed -n "s/.*[?&]$2=\([^&#]*\).*/\1/p" <<<"$1"; }
id() { local rest=${1#vless://}; echo "${rest%%@*}"; }
reality() { sudo morzer task run client-config --output | grep -m1 '^vless://.*security=reality.*type=tcp'; }
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }
set_secret() { printf %s "$2" | sudo morzer secret set "$1" >/dev/null || die "secret set $1 failed"; }

link=$(reality) || die "client-config printed no REALITY link"
client() { # <name> <socks port> <pbk> <sid>: a REALITY client of the link's device, with that key
  local dir=/rig/clients/$1
  mkdir -p "${dir}"
  jq -n --argjson socks "$2" --arg id "$(id "${link}")" --arg enc "$(param "${link}" encryption)" \
    --arg sni "$(param "${link}" sni)" --arg pbk "$3" --arg sid "$4" '
    {inbounds: [{listen: "127.0.0.1", port: $socks, protocol: "socks"}],
     outbounds: [{protocol: "vless",
       settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
       streamSettings: {network: "raw", security: "reality",
         realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >"${dir}/client.json"
  chmod -R a+rX "${dir}"
  sudo docker rm -f "dotdash-rig-$1" >/dev/null 2>&1 || true
  sudo docker run -d --name "dotdash-rig-$1" --network host -v "${dir}:/etc/xray:ro" "${xray}" >/dev/null
}
gets_through() { # <socks port>
  [ "$(curl -fsS --max-time 15 --retry 30 --retry-delay 2 --retry-all-errors \
    --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null)" = ok ]
}
locked_out() { # <socks port>
  sleep 2
  ! curl -fsS -o /dev/null --max-time 10 --socks5-hostname "127.0.0.1:$1" "${target}" 2>/dev/null
}
pair() { # a fresh key pair: "<private> <public>"
  local out
  out=$(sudo docker run --rm "${xray}" x25519)
  echo "$(sed -n 's/^PrivateKey: //p' <<<"${out}") $(sed -n 's/^Password (PublicKey): //p' <<<"${out}")"
}

old_key=$(sudo cat "${secrets}/reality_key")
old_sid=$(sudo cat "${secrets}/reality_short_id")
old_pbk=$(param "${link}" pbk)
read -r next_key next_pbk <<<"$(pair)"
next_sid=$(openssl rand -hex 8)
read -r _ stray_pbk <<<"$(pair)"

# 1. The next key second.
set_secret reality_key_second "${next_key}"
set_secret reality_short_id_second "${next_sid}"
set_config reality_second_key=true
client key-old 11180 "${old_pbk}" "${old_sid}"
client key-next 11181 "${next_pbk}" "${next_sid}"
client key-stray 11182 "${stray_pbk}" "${next_sid}"
gets_through 11180 || die "with a second key, a device on the current key got nothing"
gets_through 11181 || die "a device on the second key got nothing"
locked_out 11182 || die "a device on a key that is neither got through"
[ "$(param "$(reality)" pbk)" = "${old_pbk}" ] || die "with a second key, links stopped carrying the current one"
echo "57-second-key.sh: with the next key second, devices on either key get through, a stray key does not"

# 2. Swapped.
set_secret reality_key "${next_key}"
set_secret reality_short_id "${next_sid}"
set_secret reality_key_second "${old_key}"
set_secret reality_short_id_second "${old_sid}"
gets_through 11180 || die "swapped, a device on the old key got nothing"
gets_through 11181 || die "swapped, a device on the new key got nothing"
[ "$(param "$(reality)" pbk)" = "${next_pbk}" ] || die "swapped, links do not carry the new key"
echo "57-second-key.sh: swapped, devices on either key still get through, and links carry the new one"

# 3. The second key off.
set_config reality_second_key=false
locked_out 11180 || die "with the second key off, a device on the old key still got through"
gets_through 11181 || die "with the second key off, a device on the new key got nothing"
echo "57-second-key.sh: with the second key off, only the new key gets through"

# The rig's own key back, for the scripts after this one.
set_secret reality_key "${old_key}"
set_secret reality_short_id "${old_sid}"
sudo morzer config unset reality_second_key >/dev/null || die "could not unset reality_second_key"
gets_through 11180 || die "with the rig's own key back, a device on it got nothing"
sudo docker rm -f dotdash-rig-key-old dotdash-rig-key-next dotdash-rig-key-stray >/dev/null
echo "57-second-key.sh: the rig's own key is back"
