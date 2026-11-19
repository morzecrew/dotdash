#!/usr/bin/env bash
# Beside the operator's own web server: listen=127.0.0.1 with spare
# https_port and http_port moves both published ports to loopback, the cover
# site answers there through REALITY, nothing is left on 443 or 80, and
# entry_port=443 keeps every link and the facts on 443, the port a web server
# in front would take. Then the defaults again, published on 443 and 80 on
# every address: IPv4, and IPv6 where Docker publishes it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'entry_port:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

defaults() { sudo morzer config unset listen https_port http_port entry_port >/dev/null; }
trap 'defaults || true' EXIT
mapping() { sudo docker port "$(service_container "$1")" "$2" 2>/dev/null | LC_ALL=C sort | paste -sd' '; }

sudo morzer config set listen=127.0.0.1 https_port=9443 http_port=9080 entry_port=443 >/dev/null ||
  die "config set listen=127.0.0.1 https_port=9443 http_port=9080 entry_port=443 failed"

[ "$(mapping gate 443/tcp)" = 127.0.0.1:9443 ] || die "the gate publishes 443 on '$(mapping gate 443/tcp)', not 127.0.0.1:9443 alone"
[ "$(mapping caddy 80/tcp)" = 127.0.0.1:9080 ] || die "caddy publishes 80 on '$(mapping caddy 80/tcp)', not 127.0.0.1:9080 alone"
echo "${0##*/}: REALITY on 127.0.0.1:9443 and the site's HTTP on 127.0.0.1:9080, nothing on 443 or 80"

domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
code=$(curl --noproxy '*' -sk -o /dev/null -w '%{http_code}' --max-time 10 \
  --resolve "${domain}:9443:127.0.0.1" "https://${domain}:9443/" || true)
[ "${code}" = 200 ] || die "the cover site answers ${code:-nothing} on 127.0.0.1:9443, not 200"
echo "${0##*/}: the cover site answers through REALITY on loopback"

links=$(sudo morzer task run client-config --output | grep '^vless://' || true)
[ -n "${links}" ] || die "client-config printed no link"
off=$(grep -E 'security=(reality|tls)' <<<"${links}" | grep -vcE '^vless://[^@]+@[^:/?]+:443\?' || true)
[ "${off}" = 0 ] || die "${off} REALITY or XHTTP link(s) name a port other than entry_port 443"
port=$(sudo morzer task run facts --output | jq -r .https_port)
[ "${port}" = 443 ] || die "facts give https_port ${port}, not entry_port 443"
echo "${0##*/}: links and facts keep entry_port 443"

defaults || die "setting the defaults back failed"
trap - EXIT
[[ $(mapping gate 443/tcp) =~ ^0\.0\.0\.0:443(\ \[::\]:443)?$ ]] || die "back on the defaults, the gate publishes 443 on '$(mapping gate 443/tcp)'"
[[ $(mapping caddy 80/tcp) =~ ^0\.0\.0\.0:80(\ \[::\]:80)?$ ]] || die "back on the defaults, caddy publishes 80 on '$(mapping caddy 80/tcp)'"
echo "${0##*/}: back on 443 and 80, every address: $(mapping gate 443/tcp)"
