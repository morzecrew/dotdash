#!/usr/bin/env bash
# Subscriptions (the subscription parameter). With it on, client-config prints
# each device's URL alone, which serves exactly the links --full prints, base64,
# once the subscription service reports healthy; a guessed URL gets the site's
# own 404; a device whose line is deleted loses its URL, and a device added
# gets one, each as soon as the secret is set; rotating subscription_key moves
# every URL; and with it off, none answers.
# After 45-revocation.sh, so the links served are those of its rotated keys.
# No URL or link is printed: a failure names the step, not the credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo morzer config list 2>/dev/null | grep -qE '^ +subscription +'; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

domain=$(sudo docker exec "$(service_container caddy)" printenv DOMAIN)
fetch() { # <url> [curl options...]: the body, or nothing for anything but 200
  curl -fsS --max-time 10 --retry 5 --retry-delay 1 --retry-all-errors --cacert /rig/clients/root.pem \
    --resolve "${domain}:443:127.0.0.1" "${@:2}" "$1" 2>/dev/null || true
}
headers() { # <url>: the status line and headers, Date aside, sorted
  curl -s -o /dev/null -D - --max-time 10 --cacert /rig/clients/root.pem \
    --resolve "${domain}:443:127.0.0.1" "$1" | tr -d '\r' | grep -vi '^date:' | sort || true
}
status() { # <url>: the status code alone
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert /rig/clients/root.pem \
    --resolve "${domain}:443:127.0.0.1" "$1" || true
}
url_of() { # [client]: the subscription URL client-config prints for it
  sudo morzer task run client-config --output ${1:+-- "$1"} | grep -m1 -E "^https://${domain}/[0-9a-f]{32}\$" || true
}
# The rehearsal runs this against the published release too. One from before
# --full prints each device's links beside its URL, and has no healthcheck on
# the subscription service.
if sudo grep -q -- '--full' /opt/dotdash/current/tasks/client-config.sh; then full=(--full); else full=(); fi
links_of() { # [client]: its vless:// links, which --full prints
  local args=(${full[@]+"${full[@]}"} ${1:+"$1"})
  sudo morzer task run client-config --output ${args[@]+-- "${args[@]}"} | grep '^vless://' || true
}
health() { # the subscription service's health
  sudo docker inspect -f '{{.State.Health.Status}}' "$(service_container subscription)" 2>/dev/null || true
}
restore() {
  sudo morzer config unset relays >/dev/null 2>&1 || true
  [ -z "${before:-}" ] || printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null 2>&1 || true
  sudo morzer config unset subscription >/dev/null 2>&1 || true
}
trap restore EXIT

[ -z "$(url_of)" ] || die "client-config prints a subscription URL with the parameter off"
sudo morzer config set subscription=true >/dev/null || die "could not turn subscriptions on"
url=$(url_of)
[ -n "${url}" ] || die "client-config prints no subscription URL with the parameter on"
if [ ${#full[@]} -gt 0 ]; then
  ! grep -q '^vless://' <<<"$(sudo morzer task run client-config --output)" \
    || die "client-config prints links beside the subscription URL without --full"
  for _ in $(seq 30); do [ "$(health)" = healthy ] && break; sleep 1; done
  [ "$(health)" = healthy ] || die "the subscription service is not healthy: $(health)"
fi
served=$(fetch "${url}" | base64 -d 2>/dev/null || true)
[ -n "${served}" ] || die "the subscription URL serves nothing"
[ "${served}" = "$(links_of)" ] || die "the subscription does not serve the links client-config prints"
echo "${0##*/}: client-config prints a device's URL alone, and it serves exactly its links"

if sudo grep -q 'Cache-Control no-store' /opt/dotdash/current/caddy/Caddyfile; then
  grep -qix 'cache-control: no-store' <<<"$(headers "${url}")" || die "a subscription is served without Cache-Control: no-store"
  echo "${0##*/}: a subscription is served no-store, so nothing between keeps a copy"
fi

# An own-site relay fetches the subscription for devices inside the country:
# client-config adds that URL, the same token, under the server's; a relay on
# a borrowed site, without the mark, gets none.
if sudo grep -q sub_through /opt/dotdash/current/tasks/client-config.sh; then
  printf '%s\n%s\n' "relay-a.test site-a.test pbkA 0011223344556677 mlkem.a" \
    "198.51.100.7 relay-b.test pbkB 8899aabbccddeeff mlkem.b own-site" | sudo morzer config set --set-file relays=- >/dev/null
  text=$(sudo morzer task run client-config --output)
  [ "$(grep -m1 '^https://' <<<"${text}")" = "${url}" ] || die "the server's URL is no longer the first a device gets"
  grep -qx "through the relay relay-b.test: https://relay-b.test/${url##*/}" <<<"${text}" ||
    die "client-config prints no URL through the own-site relay"
  ! grep -q 'site-a.test' <<<"${text}" || die "a relay on a borrowed site got a subscription URL"
  sudo morzer config unset relays >/dev/null
  echo "${0##*/}: an own-site relay adds the same subscription through it; a borrowed site, none"
fi

guess="https://${domain}/$(random | cut -c1-32)"
[ "$(status "${guess}")" = 404 ] || die "a guessed subscription URL is not a 404"
[ "$(headers "${guess}")" = "$(headers "https://${domain}/$(random | cut -c1-12)")" ] \
  || die "a guessed subscription URL answers otherwise than any missing page"
echo "${0##*/}: a guessed URL gets the site's own 404"

before=$(sudo cat /run/dotdash/secrets/vless_clients)
spare=$(cat /proc/sys/kernel/random/uuid)
printf '%s\n%s spare\n' "${before}" "${spare}" | sudo morzer secret set vless_clients >/dev/null
spare_url=$(url_of spare)
[ -n "${spare_url}" ] && [ "$(fetch "${spare_url}" | base64 -d 2>/dev/null)" = "$(links_of spare)" ] \
  || die "a device added to vless_clients gets no subscription"
printf '%s\n' "${before}" | sudo morzer secret set vless_clients >/dev/null
[ "$(status "${spare_url}")" = 404 ] || die "a deleted device's subscription still answers"
[ -n "$(fetch "${url}")" ] || die "deleting one device's line took another's subscription"
echo "${0##*/}: a device added gets a subscription, and a deleted one loses it"

sudo morzer secret rotate subscription_key >/dev/null || die "could not rotate subscription_key"
moved=$(url_of)
[ -n "${moved}" ] && [ "${moved}" != "${url}" ] || die "rotating subscription_key did not move the URL"
[ "$(status "${url}")" = 404 ] || die "the URL from before the rotation still answers"
[ "$(fetch "${moved}" | base64 -d 2>/dev/null)" = "$(links_of)" ] || die "the moved URL does not serve the links"
echo "${0##*/}: rotating subscription_key moves every URL"

sudo morzer config set subscription=false >/dev/null
[ "$(status "${moved}")" = 404 ] || die "a subscription still answers with the parameter off"
echo "${0##*/}: with subscriptions off, none answers"
