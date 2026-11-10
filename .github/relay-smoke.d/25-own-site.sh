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
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo docker rm -f relay-rig-own >/dev/null 2>&1 || true
}
trap restore EXIT

entry() { sudo morzer task run relay-entry --output -- 127.0.0.1 | grep -m1 '^127\.0\.0\.1 ' || true; }
device() { # <port> <site>: an Xray client of the relay, HTTP proxy on 127.0.0.1:<port>
  local host site pbk sid enc
  read -r host site pbk sid enc <<<"$(entry)"
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

sudo morzer config unset installation.profile >/dev/null || die "could not drop the own-site profile"
device 18083 www.gstatic.com
gets_out 18083 || die "a device on the borrowed site did not get out once the profile was dropped"
sudo docker rm -f relay-rig-own >/dev/null
echo "${0##*/}: without the profile, the borrowed site and its devices are back"
