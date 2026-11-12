#!/usr/bin/env bash
# direct=false keeps the servers out of devices' links. With an own-site relay,
# a plain one, a CDN host and subscriptions on:
# - no link, outbound or subscription URL names the server's domain, and the
#   config is valid with only the relays' and the CDN's outbounds;
# - the subscription URL comes through the own-site relay alone, and the
#   subscription file the server serves holds the same links;
# - with no relay and no CDN host, client-config names the device that gets no
#   links and no subscription URL;
# - with direct back to true, the server's links are back.
# No link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qx '  direct:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates direct"
  exit 0
fi

domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
restore() {
  sudo morzer config set direct=true >/dev/null 2>&1 || true
  sudo morzer config unset relays >/dev/null 2>&1 || true
  sudo morzer config set cdn_hosts=none subscription=false >/dev/null 2>&1 || true
}
trap restore EXIT

# Captured, then read: a reader that stops early would kill the task's output.
config() { sudo morzer task run client-config --output -- "$@"; }
names_server() { grep -qF "${domain}" <<<"$1"; }

printf '%s\n' \
  "relay-o.test site-o.test pbkO 0011223344556677 mlkem.o own-site 00112233445566778899aabbccddeeff" \
  "relay-p.test site-p.test pbkP 8899aabbccddeeff mlkem.p" |
  sudo morzer config set --set-file relays=- >/dev/null || die "could not set relays"
sudo morzer config set cdn_hosts=cdn-d.test subscription=true >/dev/null || die "could not set cdn_hosts and subscription"
sudo morzer config set direct=false >/dev/null || die "could not set direct=false"

text=$(config --full)
! names_server "${text}" || die "with direct=false, client-config still names the server's domain"
tags=$(awk '/^Xray client config/{on=1} on && /^\{$/{p=1} p{print} p && /^\}$/{exit}' <<<"${text}" |
  jq -r '[.outbounds[].tag | select(startswith("dotdash-"))] | join(" ")') ||
  die "with direct=false, the Xray config is not valid JSON"
[ "${tags}" = "dotdash-relay-1 dotdash-relay-1-xhttp dotdash-relay-2 dotdash-cdn-1" ] ||
  die "with direct=false, the config's outbounds are not the relays' and the CDN's alone: ${tags}"
grep -qE '^through the relay site-o\.test: https://site-o\.test/[0-9a-f]{32}$' <<<"${text}" ||
  die "with direct=false, no subscription URL through the own-site relay"
echo "${0##*/}: with direct=false, no link, outbound or URL names the server, only relays and the CDN"

# The file behind the URL holds what --full prints, served once the
# subscription service has written it again.
token=$(sed -nE 's|^through the relay site-o\.test: https://site-o\.test/([0-9a-f]{32})$|\1|p' <<<"${text}" | sed -n 1p)
want=$(grep '^vless://' <<<"$(config --full "$(sudo awk '$1 !~ /^#/ && NF { print $1; exit }' /run/dotdash/secrets/vless_clients)")" | base64 -w 0)
got=
for _ in $(seq 30); do
  got=$(curl -fsS --max-time 10 --cacert /rig/clients/root.pem --resolve "${domain}:443:127.0.0.1" \
    "https://${domain}/${token}" 2>/dev/null || true)
  [ "${got}" != "${want}" ] || break
  sleep 2
done
[ "${got}" = "${want}" ] || die "the subscription file does not hold the links direct=false prints"
! base64 -d <<<"${got}" | grep -qF "${domain}" || die "the subscription file names the server's domain"
echo "${0##*/}: the subscription the relay carries holds the same links"

sudo morzer config unset relays >/dev/null || die "could not unset relays"
sudo morzer config set cdn_hosts=none >/dev/null || die "could not unset cdn_hosts"
err=$(config --full 2>&1 >/dev/null)
grep -qF ': no links: direct=false keeps the servers out' <<<"${err}" ||
  die "a device with no relay and no CDN host is not named as getting no links"
grep -qF ': no subscription URL: direct=false' <<<"${err}" ||
  die "a device with no own-site relay is not named as getting no subscription URL"
echo "${0##*/}: a device left with nothing is named"

sudo morzer config set direct=true >/dev/null || die "could not set direct=true"
names_server "$(config --full)" || die "with direct=true, the server's links are not back"
echo "${0##*/}: with direct=true, the server's links are back"
