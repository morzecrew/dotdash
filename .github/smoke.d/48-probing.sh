#!/usr/bin/env bash
# Active probing. Whatever reaches port 443 without a client's credentials
# must get exactly what Caddy alone would give, since REALITY relays it to
# Caddy untouched. Each probe goes to the public port, and to Caddy itself
# inside its own network namespace as the reference; the answers must match,
# Date aside. The probes: HTTPS with ordinary and odd methods, on / and on a
# random path, over HTTP/2 and HTTP/1.1; plain HTTP on 443; TLS naming the
# site, another name or none; and bytes that are no ClientHello. Every HTTPS
# answer must also carry the site's headers and name no server, version or
# stack. Before 50-quiet-logs.sh, which then reads the logs the probes left.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

# A release from before the site's headers covered errors has nothing to check.
if ! sudo grep -qF 'handle_errors' /opt/dotdash/current/caddy/Caddyfile; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

caddy=$(service_container caddy)
domain=$(sudo docker exec "${caddy}" printenv DOMAIN)
pid=$(sudo docker inspect -f '{{.State.Pid}}' "${caddy}")
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT

# Run a probe on the public port, or on Caddy's own 443 from inside its
# namespace; both are 127.0.0.1:443 where the probe runs.
public() { "$@"; }
direct() { sudo nsenter -t "${pid}" -n "$@"; }

https() { # <where> <curl options...>: the status line and headers without Date, then the body's hash
  "$1" curl --noproxy '*' -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" \
    -D - -o "${tmp}/body" "${@:2}" 2>/dev/null | tr -d '\r' | grep -vi '^date:' || true
  touch "${tmp}/body"
  sha256sum <"${tmp}/body" | cut -d' ' -f1
  [ "$1" = direct ] || cat "${tmp}/body" >>"${tmp}/bodies"
  rm -f "${tmp}/body"
}
tls() { # <where> <s_client options...>: the certificate's fingerprint, or the alert
  "$1" openssl s_client -connect 127.0.0.1:443 "${@:2}" </dev/null >"${tmp}/tls" 2>&1 || true
  openssl x509 -noout -fingerprint -sha256 <"${tmp}/tls" 2>/dev/null || grep -o 'alert [a-z ]*' "${tmp}/tls" | sort -u
}
raw() { # <where> <printf format>: what comes back for those bytes, as hex
  # shellcheck disable=SC2059 # the format is the probe
  printf "reply:%s\n" "$(printf "$2" | "$1" timeout 6 nc -w 3 127.0.0.1 443 2>/dev/null | od -An -tx1 | tr -d ' \n')"
}

checked=0
same() { # <name> <probe> <args...>: the public answer is Caddy's own
  # Up to three tries: through REALITY's fallback the public side is slower,
  # and one request timing out in a busy rig is not an answer of its own. A
  # real difference answers the same way every time.
  local want got try
  for try in 1 2 3; do
    want=$("$2" direct "${@:3}")
    got=$("$2" public "${@:3}")
    [ -n "${want}" ] && [ "${got}" = "${want}" ] && break
    [ "${try}" = 3 ] || sleep 1
  done
  [ -n "${want}" ] || die "$1: Caddy itself gave nothing to compare with"
  [ "${got}" = "${want}" ] || die "$1: the public port answers otherwise than Caddy itself"
  checked=$((checked + 1))
  printf '%s\n' "${got}" >>"${tmp}/answers"
}

url="https://${domain}"
path="/$(random | cut -c1-12)"
for version in --http2 --http1.1; do
  for target in / "${path}"; do
    same "GET ${target} ${version}" https "${version}" "${url}${target}"
    same "HEAD ${target} ${version}" https "${version}" --head "${url}${target}"
    same "POST ${target} ${version}" https "${version}" -d probe=1 "${url}${target}"
    for method in OPTIONS PUT DELETE PATCH TRACE PROPFIND FOO; do
      same "${method} ${target} ${version}" https "${version}" -X "${method}" "${url}${target}"
    done
  done
done
https public --http2 "${url}/" | grep -q '^HTTP/2 200' || die "GET / on the public port is not the site"
https public --http2 "${url}${path}" | grep -q '^HTTP/2 404' || die "a random path on the public port is not a 404"
# Every HTTPS answer so far: the site's headers, and nothing naming what runs.
[ "$(grep -c '^HTTP/' "${tmp}/answers")" = "$(grep -ci '^strict-transport-security:' "${tmp}/answers")" ] \
  || die "an HTTPS answer lacks the site's headers"
! grep -qiE '^(server|x-powered-by|via):' "${tmp}/answers" || die "an HTTPS answer names the server"

same "plain HTTP on 443" https --http1.1 "http://${domain}:443/"
same "TLS naming the site" tls -servername "${domain}"
same "TLS naming another site" tls -servername www.example.org
same "TLS naming none" tls -noservername
same "a malformed ClientHello" raw '\x16\x03\x01\x00\x0c\x01\x00\x00\x08\x03\x03garbag'
same "a cut-off ClientHello" raw '\x16\x03\x01\x02\x00\x01\x00\x01\xfc\x03\x03'
same "bytes that are no TLS" raw 'SSH-2.0-OpenSSH_9.9\r\n'
openssl s_client -connect 127.0.0.1:443 -servername "${domain}" -CAfile /rig/clients/root.pem </dev/null 2>&1 \
  | grep -q 'Verify return code: 0' || die "the certificate on the public port is not the site's"
! cat "${tmp}/answers" "${tmp}/bodies" | grep -qaiE 'caddy|xray|golang|go1\.[0-9]|goroutine|panic|traceback' \
  || die "an answer names the software or shows a stack"
echo "${0##*/}: ${checked} probes without credentials get exactly what Caddy itself gives, and nothing names it"
