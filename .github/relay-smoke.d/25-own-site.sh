#!/usr/bin/env bash
# The own-site profile: the relay serves a site of its own under its own
# domain, and REALITY hands Caddy every connection without the relay's key.
# With a domain set (relay.test; the rig has no DNS, so the probe is told the
# address) and Caddy's own CA (cert_issuer=internal, offline):
#
# - REALITY's target is Caddy, under the relay's domain, and relay-entry names
#   that domain as the site;
# - a probe without the key gets the relay's own certificate for that name and
#   the bundled page, titled with it; port 80 redirects there, naming no
#   server; the facts carry the days that certificate has left;
# - a device whose link names the domain gets out through the relay, and
#   doctor passes, the cover-site check included;
# - a device's subscription goes on to its server group through the relay's
#   tunnel by its token's first 12 hex characters, unless a CDN marks it as
#   passed on or it comes under another name; a token no group has, or its
#   server lacks, and any other path, get the relay's site; relay-entry's
#   line carries xhttp=;
# - with the XHTTP path relay-entry adds, a device gets out over XHTTP behind
#   the relay's site, under its certificate;
# - an app behind the site (cover) serves it, and doctor passes, its
#   cover-site check on the own site; with the app gone, doctor fails;
# - dropping the profile brings back the borrowed site, and devices on it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

domain=relay.test
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

restore() {
  sudo morzer config unset cdn_only >/dev/null 2>&1 || true
  sudo morzer config set cdn_hosts=none >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-own relay-rig-xhttp >/dev/null 2>&1 || true
  sudo docker start relay-rig-server >/dev/null 2>&1 || true
}
trap restore EXIT

entry() { sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^relay/1 ' || true; }
device() { # <port> <site>: an Xray client of the relay, HTTP proxy on 127.0.0.1:<port>
  local host site pbk sid enc
  read -r _ _ _ host site pbk sid enc _ <<<"$(entry)"
  [ "${site}" = "$2" ] || die "relay-entry gave the site as ${site}, not $2"
  mkdir -p /rig/relay/own
  jq -n --arg host "${host}" --arg site "${site}" --arg pbk "${pbk}" --arg sid "${sid}" --arg enc "${enc}" \
    --arg id "$(cat /rig/relay/device)" --argjson port "$1" '
    {inbounds: [{listen: "127.0.0.1", port: $port, protocol: "http"}],
     outbounds: [{protocol: "vless",
       settings: {address: $host, port: 443, id: $id, encryption: $enc, flow: "xtls-rprx-vision"},
       streamSettings: {network: "raw", security: "reality", realitySettings:
         {serverName: $site, fingerprint: "chrome", password: $pbk, shortId: $sid}}}]}' >/rig/relay/own/config.json
  chmod -R a+rX /rig/relay/own
  sudo docker rm -f relay-rig-own >/dev/null 2>&1 || true
  sudo docker run -d --name relay-rig-own --network host -v /rig/relay/own:/etc/xray:ro "${xray}" >/dev/null
}
gets_out() { # <port>: whether probe_url answers 204 through that device
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 5 --retry-delay 2 --retry-all-errors \
    --proxy "http://127.0.0.1:$1" https://www.gstatic.com/generate_204 || true)" = 204 ]
}

# The domain and the issuer first, then the profile, which starts Caddy.
set_config "installation.domains=${domain}"
set_config cert_issuer=internal
set_config installation.profile=own-site

sudo jq -e --arg d "${domain}" '.inbounds[0].streamSettings.realitySettings
  | .target == "caddy:443" and .serverNames == [$d]' /etc/dotdash-relay/xray.json >/dev/null ||
  die "REALITY's target is not Caddy under ${domain}: $(sudo jq -c '.inbounds[0].streamSettings.realitySettings | {target, serverNames}' /etc/dotdash-relay/xray.json)"
echo "${0##*/}: REALITY's target is the relay's own site, under its own domain"

# A probe without the key: REALITY hands it to Caddy.
san=$(openssl s_client -connect 127.0.0.1:443 -servername "${domain}" </dev/null 2>/dev/null |
  openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
grep -q "DNS:${domain}" <<<"${san}" || die "a probe did not get a certificate for ${domain}: ${san:-none}"
page=$(curl -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" || true)
grep -q "<title>${domain}</title>" <<<"${page}" || die "a probe did not get the bundled page titled ${domain}"
echo "${0##*/}: a probe without the key gets the relay's own certificate and page"
# Port 80 redirects to HTTPS as Caddy would, and names no server, as 443.
head=$(curl -sI --max-time 10 -H "Host: ${domain}" http://127.0.0.1/x?y || true)
grep -q '^HTTP/1.1 308' <<<"${head}" || die "port 80 did not redirect: ${head}"
grep -qi "^location: https://${domain}/x?y" <<<"${head}" || die "port 80 did not redirect to HTTPS: ${head}"
! grep -qi '^server:' <<<"${head}" || die "port 80 names its server: ${head}"
echo "${0##*/}: port 80 redirects to HTTPS and names no server"
# The facts carry the whole days left on that certificate: under Caddy's
# own CA, whose certificates last 12 hours, 0.
facts=$(sudo morzer task run facts --output 2>/dev/null) || die "the facts task failed under own-site"
jq -e '(.cert_days | type) == "number" and .cert_days >= 0' <<<"${facts}" >/dev/null ||
  die "the facts carry no days left on the site's certificate: $(jq -c '{cert_days}' <<<"${facts}")"
echo "${0##*/}: the facts carry the days left on the site's certificate, $(jq .cert_days <<<"${facts}")"

device 18083 "${domain}"
gets_out 18083 || die "a device naming ${domain} did not get out through the relay"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the own site up: $(sudo morzer doctor 2>&1 | tail -5)"
echo "${0##*/}: a device naming the relay's domain gets out, and doctor passes"

# site <host> <path> [curl args]: the relay's site's status and body there.
site() { curl -sk --max-time 40 -w '\n%{http_code}' --resolve "$1:443:127.0.0.1" "${@:3}" "https://$1$2" || true; }
# phone's token (pre-apply/10-server.sh), whose first 12 hex characters its
# group's list carries: the relay routes it to that group's server, whose
# internal listener serves it.
token=$(cat /rig/relay/token)
# What the site answers a path that is no subscription: its 404.
cover=$(site "${domain}" "/${token}0")
[[ ${cover} == *$'\n404' ]] || die "a path that is no subscription did not get the site's 404: $(tail -c 300 <<<"${cover}")"
for _ in $(seq 20); do [ "$(site "${domain}" "/${token}")" = $'subscription of phone\n200' ] && break; sleep 3; done
[ "$(site "${domain}" "/${token}")" = $'subscription of phone\n200' ] ||
  die "phone's subscription did not come from its server through the relay: $(site "${domain}" "/${token}" | tail -c 300)"
[ "$(site "${domain}" "/${token}.json")" = $'{"subscription_of": "phone"}\n200' ] || die "phone's .json subscription did not come through the relay"
# A request a CDN marks as passed on, or under another name than the relay's
# domain (a CDN that strips its headers is told apart by its Host), gets the
# site; so does a token no group's list has (no route at Xray), and one
# whose prefix a group has but whose server lacks it (its 404).
[ "$(site "${domain}" "/${token}" -H 'X-Forwarded-For: 203.0.113.9')" = "${cover}" ] ||
  die "a subscription request a CDN marks as passed on did not get the relay's site"
[ "$(site cdn-b.test "/${token}")" = "${cover}" ] || die "a subscription request under another name than the relay's domain did not get the relay's site"
[ "$(site "${domain}" "/0123456789ab${token:12}")" = "${cover}" ] || die "a token no group has did not get the relay's site"
[ "$(site "${domain}" "/${token:0:12}00000000000000000000")" = "${cover}" ] || die "a token its server lacks did not get the relay's site"
[[ $(entry) == *" xhttp="* ]] || die "relay-entry's line carries no xhttp= under own-site: $(entry | cut -d' ' -f1-5)"
echo "${0##*/}: a device's subscription comes from its group's server through the tunnel by its prefix; a token no group has, or its server lacks, gets the relay's site; the line carries xhttp="

read -r _ _ _ _ site _ _ enc _ <<<"$(entry)"
path=$(entry | grep -o ' xhttp=[^ ]*' | cut -d= -f2)
[ -n "${path}" ] || die "relay-entry gives no XHTTP path under own-site"
# The CA beside the config, not in it: the image refuses a file in
# /etc/xray that is not JSON.
mkdir -p /rig/relay/xhttp /rig/relay/xhttp-ca
sudo docker exec "$(service_container caddy)" cat /data/caddy/pki/authorities/local/root.crt |
  tee /rig/relay/xhttp-ca/root.pem >/dev/null
jq -n --arg site "${site}" --arg enc "${enc}" --arg path "/${path}" --arg id "$(cat /rig/relay/device)" '
  {inbounds: [{listen: "127.0.0.1", port: 18084, protocol: "http"}],
   outbounds: [{protocol: "vless",
     settings: {address: "127.0.0.1", port: 443, id: $id, encryption: $enc},
     streamSettings: {network: "xhttp", security: "tls",
       tlsSettings: {serverName: $site, alpn: ["h2"], fingerprint: "chrome",
         certificates: [{usage: "verify", certificateFile: "/ca/root.pem"}]},
       xhttpSettings: {path: $path, host: $site, mode: "auto"}}}]}' >/rig/relay/xhttp/config.json
chmod -R a+rX /rig/relay/xhttp /rig/relay/xhttp-ca
sudo docker rm -f relay-rig-xhttp >/dev/null 2>&1 || true
sudo docker run -d --name relay-rig-xhttp --network host -v /rig/relay/xhttp:/etc/xray:ro \
  -v /rig/relay/xhttp-ca:/ca:ro "${xray}" >/dev/null
gets_out 18084 || die "a device did not get out over XHTTP behind the relay's site: $(sudo docker logs relay-rig-xhttp 2>&1 | tail -2)"
sudo docker rm -f relay-rig-xhttp >/dev/null
echo "${0##*/}: a device gets out over XHTTP behind the relay's site, with the path relay-entry gives"

# cdn_hosts: relay-entry ends the line with cdn=<names>. The rig has no CDN,
# so the relay's site stands in for one under its own name, as the server's
# 16-cdn.sh does: a device shaped for a CDN (packet-up, uploads by GET with
# the data in headers) gets out, so the relay reads uploads placed so.
set_config "cdn_hosts=${domain},cdn-b.test"
[[ $(entry) == *" cdn=${domain},cdn-b.test" || $(entry) == *" cdn=${domain},cdn-b.test cdnpath="* ]] ||
  die "relay-entry does not end the line with cdn=${domain},cdn-b.test: $(entry | grep -o 'cdn=[^ ]*' || true)"
jq '.outbounds[0].streamSettings.xhttpSettings += {mode: "packet-up", uplinkHTTPMethod: "GET",
    uplinkDataPlacement: "header", uplinkChunkSize: 16384, scMaxEachPostBytes: 8192, scMinPostsIntervalMs: 10}' \
  /rig/relay/xhttp/config.json >/rig/relay/xhttp/cdn.json
mv /rig/relay/xhttp/cdn.json /rig/relay/xhttp/config.json
chmod -R a+rX /rig/relay/xhttp
sudo docker run -d --name relay-rig-xhttp --network host -v /rig/relay/xhttp:/etc/xray:ro \
  -v /rig/relay/xhttp-ca:/ca:ro "${xray}" >/dev/null
gets_out 18084 || die "a device shaped for a CDN did not get out behind the relay's site: $(sudo docker logs relay-rig-xhttp 2>&1 | tail -2)"
sudo docker rm -f relay-rig-xhttp >/dev/null
# A CDN on its defaults sends its own name as SNI and Host: the site
# answers under any name, with the relay's certificate (fallback_sni),
# which the device checks against the relay's domain.
jq '.outbounds[0].streamSettings |= (.tlsSettings.serverName = "cdn-b.test"
    | .tlsSettings.verifyPeerCertByName = "'"${domain}"'" | .xhttpSettings.host = "cdn-b.test")' \
  /rig/relay/xhttp/config.json >/rig/relay/xhttp/cdn.json
mv /rig/relay/xhttp/cdn.json /rig/relay/xhttp/config.json
chmod -R a+rX /rig/relay/xhttp
sudo docker run -d --name relay-rig-xhttp --network host -v /rig/relay/xhttp:/etc/xray:ro \
  -v /rig/relay/xhttp-ca:/ca:ro "${xray}" >/dev/null
gets_out 18084 || die "a device under a CDN's own name did not get out behind the relay's site: $(sudo docker logs relay-rig-xhttp 2>&1 | tail -2)"
sudo docker rm -f relay-rig-xhttp >/dev/null
echo "${0##*/}: a CDN sending its own name as SNI and Host gets through the relay's site"
# The CDNs' own path (cdnpath=), to the CDN inbound: a device disguised as
# that inbound expects, which the server's CDN links through it are too
# (client-config.sh; lint.yml holds the two equal), gets out by it.
cp=$(entry | grep -o 'cdnpath=[0-9a-f]*' | cut -d= -f2)
[ "${#cp}" = 24 ] || die "relay-entry gives no cdnpath= of 24 hex characters with cdn_hosts set: $(entry | grep -o 'cdnpath=[^ ]*' || true)"
disguise=$(sudo jq -c '.inbounds[] | select(.tag == "devices-cdn").streamSettings.xhttpSettings
  | del(.path, .mode, .noSSEHeader)' /etc/dotdash-relay/xray.json)
[ "$(jq length <<<"${disguise}")" -gt 0 ] || die "the relay's config has no disguised CDN inbound"
jq --arg p "/${cp}" --argjson d "${disguise}" '.outbounds[0].streamSettings.xhttpSettings += $d + {path: $p}' \
  /rig/relay/xhttp/config.json >/rig/relay/xhttp/cdn.json
mv /rig/relay/xhttp/cdn.json /rig/relay/xhttp/config.json
chmod -R a+rX /rig/relay/xhttp
sudo docker run -d --name relay-rig-xhttp --network host -v /rig/relay/xhttp:/etc/xray:ro \
  -v /rig/relay/xhttp-ca:/ca:ro "${xray}" >/dev/null
gets_out 18084 || die "a device shaped for a CDN, disguised, did not get out by the CDNs' path: $(sudo docker logs relay-rig-xhttp 2>&1 | tail -2)"
sudo docker rm -f relay-rig-xhttp >/dev/null
grep -qF "\"cdn_path\": \"${cp}\"" <(sudo morzer task run facts --output 2>/dev/null) || die "the facts do not carry the CDNs' path"
echo "${0##*/}: relay-entry gives the CDNs' path, and a device disguised for a CDN gets out by it"
# cdn_only: the line ends with cdn-only, the facts say so, and with no CDN
# relay-entry refuses, as devices would get nothing through the relay.
set_config cdn_only=true
[[ $(entry) == *" cdn=${domain},cdn-b.test"*" cdn-only" ]] || die "relay-entry does not end the line with cdn-only under cdn_only=true"
grep -qF '"cdn_only": true' <(sudo morzer task run facts --output 2>/dev/null) || die "the facts do not carry cdn_only"
set_config cdn_hosts=none
! sudo morzer task run relay-entry --output -- 127.0.0.1 >/dev/null 2>&1 ||
  die "relay-entry prints a line under cdn_only=true with no CDN"
set_config cdn_only=false
echo "${0##*/}: cdn_only ends the line with cdn-only, and relay-entry refuses it with no CDN"
set_config cdn_hosts=none
[[ $(entry) != *cdn=* && $(entry) != *cdnpath=* ]] || die "relay-entry still prints a cdn= or cdnpath= field with cdn_hosts=none"
echo "${0##*/}: cdn_hosts ends the line with cdn=, and a device shaped for a CDN gets out behind the relay's site"

# An app behind the site (cover): Caddy's own image answering "cover
# app" and the X-Forwarded-For it got, on Caddy's network as cover-app,
# serves the site, sees the visitor's address rather than Xray's (REALITY's
# PROXY header), and doctor passes.
caddy=$(service_container caddy)
network=$(sudo docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${caddy}" | sed -n 1p)
sudo docker run -d --name relay-rig-cover-app --network "${network}" --network-alias cover-app \
  "$(sudo docker inspect -f '{{.Config.Image}}' "${caddy}")" caddy respond --listen :8080 \
  --body 'cover app {http.request.header.X-Forwarded-For}' >/dev/null
set_config cover=http://cover-app:8080
page=$(curl -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" || true)
[[ ${page} == "cover app "?* ]] || die "the relay's site is not the app's: $(head -c 200 <<<"${page}")"
xray_ips=" $(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(service_container xray)")"
[[ ${xray_ips} != *" ${page#cover app } "* ]] || die "the app sees Xray's address, ${page#cover app }, not the visitor's"
echo "${0##*/}: the app behind the site sees the visitor's address, ${page#cover app }, not Xray's"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the app up: $(sudo morzer doctor 2>&1 | tail -5)"
# The check looked at the own site, not past it as for a borrowed one.
status=$(sudo morzer status 2>&1 || true)
[[ ${status} == *"the relay's own site is up"* ]] ||
  die "cover-site did not check the own site: $(grep -F cover-site <<<"${status}")"
sudo docker stop relay-rig-cover-app >/dev/null
! sudo morzer doctor >/dev/null 2>&1 || die "doctor passes with the app behind the site gone"
set_config cover=pages
sudo docker rm -f relay-rig-cover-app >/dev/null
echo "${0##*/}: an app behind the relay's site serves it, and doctor passes; with the app gone, it fails"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the own-site profile"
set_config cdn_hosts=cdn-b.test
[[ $(entry) != *cdn=* ]] || die "relay-entry prints a cdn= field without the own-site profile"
set_config cdn_hosts=none
echo "${0##*/}: without the profile, relay-entry leaves cdn_hosts out"
device 18083 www.gstatic.com
gets_out 18083 || die "a device on the borrowed site did not get out once the profile was dropped"
sudo docker rm -f relay-rig-own >/dev/null
echo "${0##*/}: without the profile, the borrowed site and its devices are back"
