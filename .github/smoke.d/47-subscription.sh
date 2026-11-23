#!/usr/bin/env bash
# Subscriptions (the subscription parameter). With it on, client-config prints
# each device's URL alone, which serves exactly the links --full prints, base64,
# once the subscription service reports healthy, and with .json the Xray config
# --full prints, as JSON; a guessed URL gets the site's
# own 404; a device whose line is deleted loses its URL, and a device added
# gets one, each as soon as the secret is set; rotating subscription_key moves
# every URL; and with it off, none answers. A request a CDN marks as passed on
# gets the site's 404. Each answer names the subscription after the exit, its
# country's flag and IPv4 (Profile-Title), asked of the rig's stand-ins.
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
  sudo morzer config unset exit_ipv4_url exit_info_url >/dev/null 2>&1 || true
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

if sudo grep -qF '  exit_ipv4_url:' /opt/dotdash/current/manifest.yaml; then
  sudo morzer config set exit_ipv4_url=http://11.99.0.10:8000/ip4 exit_info_url=http://11.99.0.10:8000/info >/dev/null ||
    die "could not point the title at the rig's stand-ins"
  # The stand-in's exit, 203.0.113.7 in ZZ, whose flag is Z's regional indicator twice.
  want="$(printf '\360\237\207\277\360\237\207\277') 203.0.113.7"
  title=
  for _ in $(seq 30); do
    title=$(headers "${url}" | sed -n 's/^profile-title: base64://Ip' | base64 -d 2>/dev/null || true)
    [ "${title}" = "${want}" ] && break
    sleep 2
  done
  [ "${title}" = "${want}" ] || die "the subscription is not named after its exit: $(headers "${url}" | grep -i '^profile-title' || echo none)"
  echo "${0##*/}: the subscription is named after the exit, its country's flag and IPv4"
fi

if sudo grep -q 'json' /opt/dotdash/current/tasks/subscription.sh; then
  config=$(sudo morzer task run client-config --output -- --full | sed -n '/^{$/,/^}$/p')
  [ -n "${config}" ] || die "client-config --full prints no Xray config"
  [ "$(fetch "${url}.json")" = "${config}" ] || die "<url>.json does not serve the Xray config client-config prints"
  grep -qix 'content-type: application/json' <<<"$(headers "${url}.json")" || die "<url>.json is not served as JSON"
  grep -qix 'cache-control: no-store' <<<"$(headers "${url}.json")" || die "<url>.json is served without Cache-Control: no-store"
  [ "$(status "${url}.txt")" = 404 ] || die "a subscription URL with another extension is served"
  if sudo grep -q 'header Accept application/json' /opt/dotdash/current/caddy/Caddyfile; then
    [ "$(fetch "${url}" -H 'Accept: application/json')" = "${config}" ] ||
      die "the URL asked for as JSON does not serve the Xray config"
    grep -qix 'content-type: application/json' <<<"$(curl -s -o /dev/null -D - --max-time 10 --cacert /rig/clients/root.pem \
      --resolve "${domain}:443:127.0.0.1" -H 'Accept: application/json' "${url}" | tr -d '\r')" ||
      die "the URL asked for as JSON is not served as JSON"
    [ "$(fetch "${url}" -H 'Accept: */*' | base64 -d 2>/dev/null)" = "$(links_of)" ] ||
      die "the URL asked for as anything does not serve the links"
    echo "${0##*/}: the URL asked for as JSON serves the Xray config, and asked otherwise the links"
  fi
  echo "${0##*/}: <url>.json serves the device's Xray config, as JSON and no-store"
fi

if sudo grep -q -- '--local-auth' /opt/dotdash/current/tasks/client-config.sh; then
  locked() { sudo morzer task run client-config --output -- --local-auth | sed -n '/^{$/,/^}$/p'; }
  first=$(locked)
  jq -e '.inbounds | length == 1 and .[0].port == 10808 and .[0].settings.auth == "password"
    and (.[0].settings.accounts[0].pass | length) == 32' <<<"${first}" >/dev/null ||
    die "client-config --local-auth prints no Xray config with a password on its one local inbound"
  [ "$(locked)" = "${first}" ] || die "client-config --local-auth prints another password on another run"
  [ "$(fetch "${url}.json")" = "${config:-$(sudo morzer task run client-config --output -- --full | sed -n '/^{$/,/^}$/p')}" ] ||
    die "--local-auth changed the Xray config a subscription serves"
  echo "${0##*/}: --local-auth puts the same password on the one local inbound every run, and leaves the subscription's config alone"
fi

# An app on Apple's network stack, by its User-Agent, gets the links with
# Safari's hello; any other app, Chrome's, as above.
if sudo grep -q '@apple' /opt/dotdash/current/caddy/Caddyfile; then
  apple=$(fetch "${url}" -A 'Shadowrocket/2.2.60 CFNetwork/1568.100.1 Darwin/24.0.0' | base64 -d 2>/dev/null || true)
  [ "${apple}" = "$(links_of | sed 's/&fp=chrome&/\&fp=safari\&/g')" ] ||
    die "an Apple app's subscription is not its links with fp=safari"
  grep -q '&fp=safari&' <<<"${apple}" || die "an Apple app's links carry no fp=safari"
  ! grep -q 'fp=safari' <<<"${served}" || die "an app off Apple's stack got fp=safari"
  echo "${0##*/}: an Apple app's subscription carries Safari's hello, any other Chrome's"
fi

if sudo grep -q 'Cache-Control no-store' /opt/dotdash/current/caddy/Caddyfile; then
  grep -qix 'cache-control: no-store' <<<"$(headers "${url}")" || die "a subscription is served without Cache-Control: no-store"
  echo "${0##*/}: a subscription is served no-store, so nothing between keeps a copy"
fi

# A request a CDN passed on, which says so in a header, gets the site's 404;
# cdn-check, with no CDN set, says there is none.
if sudo grep -q 'not header Via' /opt/dotdash/current/caddy/Caddyfile; then
  marked() { # <header>: the status of the URL asked with it
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert /rig/clients/root.pem \
      --resolve "${domain}:443:127.0.0.1" -H "$1" "${url}" || true
  }
  for h in 'X-Forwarded-For: 203.0.113.9' 'Via: 1.1 edge' 'X-Real-IP: 203.0.113.9' 'Forwarded: for=203.0.113.9'; do
    [ "$(marked "$h")" = 404 ] || die "a subscription request marked as passed on (${h%%:*}) is served"
  done
  [ -n "$(fetch "${url}")" ] || die "the subscription no longer answers a device asking directly"
  grep -qx 'no CDN in front of this server or its relays' <<<"$(sudo morzer task run cdn-check --output)" ||
    die "cdn-check does not say there is no CDN"
  echo "${0##*/}: a subscription request a CDN marks as passed on gets the site's 404"
fi

# The decoy cdn-check fetches holds the rest of its name's hash, which tells it
# from a site that answers any path, as an app behind it may.
if sudo grep -q 'cut -c33-64' /opt/dotdash/current/tasks/subscription.sh; then
  sum=$(printf '%s:cdn-check' "$(sudo cat /run/dotdash/secrets/subscription_key)" | sha256sum)
  [ "$(fetch "https://${domain}/$(cut -c1-32 <<<"${sum}")")" = "$(cut -c33-64 <<<"${sum}")" ] ||
    die "the decoy does not hold what cdn-check knows it by"
  echo "${0##*/}: the decoy holds what cdn-check knows it by"
fi

# An own-site relay fetches the subscription for devices inside the
# restricted network: client-config adds that URL, the same token, under the
# server's; a relay on a borrowed site, without the mark, gets none.
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
[ "$(status "${spare_url}.json")" = 404 ] || die "a deleted device's Xray config still answers"
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
