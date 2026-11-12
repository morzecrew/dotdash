#!/usr/bin/env bash
# The own-site profile: the relay serves a site of its own under its own
# domain, and REALITY hands Caddy every connection without the relay's key.
# With a domain set (relay.test; the rig has no DNS, so the probe is told the
# address) and Caddy's own CA (cert_issuer=internal, offline):
#
# - REALITY's target is Caddy, under the relay's domain, and relay-entry names
#   that domain as the site;
# - a probe without the key gets the relay's own certificate for that name and
#   the bundled page, titled with it;
# - a device whose link names the domain gets out through the relay, and
#   doctor passes, the cover-site check included;
# - a subscription path goes on to the dotdash servers through the relay's
#   tunnel, unless a CDN marks it as passed on, any other path stays the
#   relay's site, and relay-entry marks the line own-site;
# - with the XHTTP path relay-entry adds, a device gets out over XHTTP behind
#   the relay's site, under its certificate;
# - dropping the profile brings back the borrowed site, and devices on it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^      own-site:' /opt/dotdash-relay/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates the own-site profile"
  exit 0
fi

domain=relay.test
xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
set_config() { sudo morzer config set "$@" >/dev/null || die "config set $* failed"; }

restore() {
  sudo morzer config set cdn_hosts=none >/dev/null 2>&1 || true
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-own relay-rig-xhttp >/dev/null 2>&1 || true
}
trap restore EXIT

entry() { sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^127\.0\.0\.1 ' || true; }
device() { # <port> <site>: an Xray client of the relay, HTTP proxy on 127.0.0.1:<port>
  local host site pbk sid enc
  read -r host site pbk sid enc _ <<<"$(entry)"
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

device 18083 "${domain}"
gets_out 18083 || die "a device naming ${domain} did not get out through the relay"
sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the own site up: $(sudo morzer doctor 2>&1 | tail -5)"
echo "${0##*/}: a device naming the relay's domain gets out, and doctor passes"

if sudo grep -q SUBSCRIPTION_UPSTREAMS /opt/dotdash-relay/current/caddy/Caddyfile; then
  # The stand-in server sends dotdash_port on to www.gstatic.com:443
  # (pre-apply), so Google's 404 for a path it doesn't have proves the request
  # went through the tunnel, over TLS checked against the server's name.
  token=$(openssl rand -hex 16)
  body=$(curl -sk --max-time 40 --resolve "${domain}:443:127.0.0.1" "https://${domain}/${token}" || true)
  grep -qF 'Error 404 (Not Found)!!1' <<<"${body}" ||
    die "a subscription path did not reach the servers through the relay's tunnel: $(head -c 300 <<<"${body}")"
  if sudo grep -q 'not header Via' /opt/dotdash-relay/current/caddy/Caddyfile; then
    marked=$(curl -sk --max-time 40 --resolve "${domain}:443:127.0.0.1" -H 'X-Forwarded-For: 203.0.113.9' "https://${domain}/${token}" || true)
    ! grep -qF 'Error 404 (Not Found)!!1' <<<"${marked}" ||
      die "a subscription request a CDN marks as passed on still went on to the servers"
  fi
  other=$(curl -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" "https://${domain}/${token}0" || true)
  ! grep -qF 'Error 404 (Not Found)!!1' <<<"${other}" || die "a path that is no subscription went on to the servers"
  [ "$(awk '{ print $6 }' <<<"$(entry)")" = own-site ] || die "relay-entry does not mark the line own-site: $(entry | cut -d' ' -f1,2,6)"
  echo "${0##*/}: a subscription path reaches the servers through the tunnel, and relay-entry marks the line own-site"
fi

if sudo jq -e '[.inbounds[].tag] | index("devices-xhttp")' /etc/dotdash-relay/xray.json >/dev/null; then
  read -r _ site _ _ enc own path _ <<<"$(entry)"
  [ "${own}" = own-site ] && [ -n "${path}" ] || die "relay-entry gives no XHTTP path under own-site: $(entry | cut -d' ' -f1,2,6)"
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
  if sudo grep -q '^  cdn_hosts:' /opt/dotdash-relay/current/manifest.yaml; then
    set_config "cdn_hosts=${domain},cdn-b.test"
    [[ $(entry) == *" cdn=${domain},cdn-b.test" ]] || die "relay-entry does not end the line with cdn=${domain},cdn-b.test: $(entry | grep -o 'cdn=[^ ]*' || true)"
    jq '.outbounds[0].streamSettings.xhttpSettings += {mode: "packet-up", uplinkHTTPMethod: "GET",
        uplinkDataPlacement: "header", uplinkChunkSize: 16384, scMaxEachPostBytes: 32768, scMinPostsIntervalMs: 10}' \
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
    if sudo grep -q fallback_sni /opt/dotdash-relay/current/caddy/Caddyfile; then
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
    fi
    set_config cdn_hosts=none
    [[ $(entry) != *cdn=* ]] || die "relay-entry still prints a cdn= field with cdn_hosts=none"
    echo "${0##*/}: cdn_hosts ends the line with cdn=, and a device shaped for a CDN gets out behind the relay's site"
  fi
fi

sudo morzer config unset installation.profile >/dev/null || die "could not drop the own-site profile"
if sudo grep -q '^  cdn_hosts:' /opt/dotdash-relay/current/manifest.yaml; then
  set_config cdn_hosts=cdn-b.test
  [[ $(entry) != *cdn=* ]] || die "relay-entry prints a cdn= field without the own-site profile"
  set_config cdn_hosts=none
  echo "${0##*/}: without the profile, relay-entry leaves cdn_hosts out"
fi
device 18083 www.gstatic.com
gets_out 18083 || die "a device on the borrowed site did not get out once the profile was dropped"
sudo docker rm -f relay-rig-own >/dev/null
echo "${0##*/}: without the profile, the borrowed site and its devices are back"
