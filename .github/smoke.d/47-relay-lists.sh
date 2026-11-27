#!/usr/bin/env bash
# The relays' device lists (subscription.sh) and the internal listener that
# serves them (Caddy's 8085, behind Xray's sub outbound): a relay's Xray user,
# here a REALITY client with the id relay-config prints it, fetches its list
# through the tunnel at list.sub.dotdash.internal/<list token>, every device
# in it, with the first 12 hex characters of its subscription token once
# subscriptions are on, and a device's subscription at
# <prefix>.sub.dotdash.internal/<token>; a device's own user gets neither;
# the public site gives its 404 for a list's path.
# No list, id or token is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
dir=/rig/clients/relay-lists
restore() {
  sudo docker rm -f dotdash-rig-relay-lists dotdash-rig-relay-lists-device >/dev/null 2>&1 || true
  sudo morzer config unset relays >/dev/null 2>&1 || true
  sudo morzer config unset subscription >/dev/null 2>&1 || true
  sudo morzer config unset name >/dev/null 2>&1 || true
}
trap restore EXIT
through() { # <socks port> <url>: the body, or nothing for anything but 200; the first try after a restart of Xray fails once
  curl -fsS --max-time 10 --retry 5 --retry-delay 2 --retry-all-errors --socks5-hostname "127.0.0.1:$1" "$2" 2>/dev/null || true
}
public() { # <path>: the public site's status for it
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert /rig/clients/root.pem \
    --resolve "${domain}:443:127.0.0.1" "https://${domain}$1" || true
}
health() { sudo docker inspect -f '{{.State.Health.Status}}' "$(service_container subscription)" 2>/dev/null || true; }
ready() { for _ in $(seq 60); do [ "$(health)" = healthy ] && return 0; sleep 1; done; die "the subscription service is not healthy: $(health)"; }

sudo morzer config set name=s1 >/dev/null || die "could not set name"
printf '%s\n' "relay/1 r1 0123456789abcdef relay-1.test relay-1.test pbkR000000000000000000000000000000000000000 0011223344556677 mlkem768x25519plus.native.0rtt.r1" |
  sudo morzer config set --set-file relays=- >/dev/null || die "could not set a relay/1 line"
read -r -a line < <(sudo morzer task run relay-config --output -- r1 2>/dev/null | grep -m1 '^server/1 ') ||
  die "relay-config printed no server/1 line for r1"
mkdir -p "${dir}"
jq -n --arg id "${line[7]}" --arg enc "${line[6]}" --arg sni "${domain}" --arg pbk "${line[4]}" --arg sid "${line[5]}" '
  {inbounds: [{listen: "127.0.0.1", port: 11101, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >"${dir}/client.json"
chmod -R a+rX "${dir}"
sudo docker rm -f dotdash-rig-relay-lists >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-relay-lists --network host -v "${dir}:/etc/xray:ro" "${xray}" >/dev/null
token=$(printf '%s:list' "${line[7]}" | sha256sum | cut -c1-32)
ids=$(sudo awk '$1 !~ /^#/ && NF { print tolower($1) }' /run/dotdash/secrets/vless_clients | sort)
entries() { awk 'NR > 1 && $1 !~ /^#/ && NF' <<<"$1"; }

# Subscriptions off: every device, no prefix.
ready
list=$(through 11101 "http://list.sub.dotdash.internal/${token}")
[ "$(head -n 1 <<<"${list}")" = "# dotdash relay list v1" ] || die "the relay's user got no list through the tunnel"
[ "$(entries "${list}" | awk '{ print tolower($1) }' | sort)" = "${ids}" ] || die "the list does not hold every device of vless_clients"
! entries "${list}" | awk 'NF > 2 { f = 1 } END { exit !f }' || die "a device in the list has a prefix with subscriptions off"
echo "${0##*/}: a relay's user fetches its list through the tunnel, every device in it"

# Subscriptions on: each device's prefix, its URL token's first 12 hex
# characters, by which the relay's own site routes its subscription here.
sudo morzer config set subscription=true >/dev/null || die "could not turn subscriptions on"
ready
list=$(through 11101 "http://list.sub.dotdash.internal/${token}")
want=$(sudo morzer task run client-config --output | sed -n "s#^https://${domain}/\([0-9a-f]\{12\}\)[0-9a-f]\{20\}\$#\1#p" | sort)
[ -n "${want}" ] && [ "$(entries "${list}" | awk '{ print $3 }' | sort)" = "${want}" ] ||
  die "the list's prefixes are not its devices' subscription tokens' first 12 hex characters"
url=$(sudo morzer task run client-config --output | grep -m1 -E "^https://${domain}/[0-9a-f]{32}\$")
t=${url##*/}
served=$(curl -fsS --max-time 10 --cacert /rig/clients/root.pem --resolve "${domain}:443:127.0.0.1" "${url}" 2>/dev/null || true)
[ -n "${served}" ] && [ "$(through 11101 "http://${t:0:12}.sub.dotdash.internal/${t}")" = "${served}" ] ||
  die "a device's subscription through the tunnel, by its prefix, is not what its URL serves"
[ -z "$(through 11101 "http://list.sub.dotdash.internal/00000000000000000000000000000000")" ] || die "a list token no relay has got a list"
echo "${0##*/}: with subscriptions on, the list carries each device's prefix, and its subscription answers through the tunnel by it"

# A device's own user, which gets through, gets nothing under the names.
mkdir -p "${dir}/device"
link=$(sudo morzer task run client-config --output -- --full | grep -m1 '^vless://.*security=reality.*type=tcp') ||
  die "client-config printed no REALITY link"
param() { sed -n "s/.*[?&]$1=\([^&#]*\).*/\1/p" <<<"${link}"; }
rest=${link#vless://}
jq -n --arg id "${rest%%@*}" --arg enc "$(param encryption)" --arg sni "$(param sni)" --arg pbk "$(param pbk)" --arg sid "$(param sid)" '
  {inbounds: [{listen: "127.0.0.1", port: 11102, protocol: "socks"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
     streamSettings: {network: "raw", security: "reality",
       realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >"${dir}/device/client.json"
chmod -R a+rX "${dir}/device"
sudo docker rm -f dotdash-rig-relay-lists-device >/dev/null 2>&1 || true
sudo docker run -d --name dotdash-rig-relay-lists-device --network host -v "${dir}/device:/etc/xray:ro" "${xray}" >/dev/null
curl -fsS -o /dev/null --max-time 15 --retry 4 --retry-delay 2 --retry-all-errors --socks5-hostname 127.0.0.1:11102 http://11.99.0.10:8000/ 2>/dev/null ||
  die "the device's own user does not get through"
! curl -fsS -o /dev/null --max-time 10 --socks5-hostname 127.0.0.1:11102 "http://list.sub.dotdash.internal/${token}" 2>/dev/null ||
  die "a device's user fetched a relay's list"
! curl -fsS -o /dev/null --max-time 10 --socks5-hostname 127.0.0.1:11102 "http://${t:0:12}.sub.dotdash.internal/${t}" 2>/dev/null ||
  die "a device's user fetched a subscription by the internal name"
echo "${0##*/}: a device's user, which gets through, is refused the internal names"

# The public site: its 404 for a list's path, as for any other.
for p in "/${token}" "/.lists/${token}"; do
  [ "$(public "$p")" = 404 ] || die "the public site does not give its 404 for a list's path"
done
echo "${0##*/}: the public site gives its 404 for a list's path"

# A relay whose line goes loses its list.
sudo morzer config set --set-file relays=- <<<"# none" >/dev/null || die "could not drop the relay/1 line"
ready
sudo docker exec "$(service_container subscription)" test ! -e "/sub/.lists/${token}" ||
  die "a relay's list stayed once its line was gone"
echo "${0##*/}: a relay whose line goes loses its list"
