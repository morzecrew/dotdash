#!/usr/bin/env bash
# cert_issuer=acme-dns. The rig has no DNS and no CA, so nothing is issued and
# the installation stays on its own issuer; what can be shown is that the
# release's Caddyfile, in the release's own Caddy image:
# - under acme-dns, with a wildcard and the registration mounted where the
#   secret goes, adapts to the wildcard and the domain as site names and an
#   issuer that solves DNS-01 through acmedns;
# - under internal, with no wildcard, adapts as before, with no acmedns;
# - and the installed release rendered CERT_WILDCARD, empty, the rig's domain
#   having two labels and its issuer not being acme-dns.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF 'values: [acme, acme-dns, internal]' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates acme-dns"
  exit 0
fi

image=$(sudo docker inspect -f '{{.Config.Image}}' "$(service_container caddy)")
dir=$(mktemp -d)
trap 'rm -rf "${dir}"' EXIT
printf '%s' '{"username": "u", "password": "p", "subdomain": "s", "server_url": "https://acme-dns.invalid"}' >"${dir}/acme_dns"
chmod -R a+rX "${dir}"
adapt() { # <issuer> <wildcard>: the release's Caddyfile adapted in its Caddy image, as JSON
  sudo docker run --rm --network none -e CERT_ISSUER="$1" -e CERT_WILDCARD="$2" -e DOMAIN=x7k2.s.dotdash.test \
    -e COVER=pages -v /opt/dotdash/current/caddy/Caddyfile:/etc/caddy/Caddyfile:ro \
    -v "${dir}/acme_dns:/run/secrets/acme_dns:ro" "${image}" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null
}

json=$(adapt acme-dns '*.s.dotdash.test') || die "the Caddyfile does not adapt under acme-dns in the release's Caddy image"
jq -e '[.apps.tls | .. | objects | select(.provider?.name? == "acmedns")] | length > 0' <<<"${json}" >/dev/null ||
  die "under acme-dns, no issuer solves DNS-01 through acmedns"
jq -e '[.apps.http | .. | arrays | select(index("*.s.dotdash.test") and index("x7k2.s.dotdash.test"))] | length > 0' \
  <<<"${json}" >/dev/null || die "under acme-dns, the site is not named for the wildcard and the domain"
echo "${0##*/}: under acme-dns, the site takes the wildcard, its DNS-01 check handed to acmedns"

json=$(adapt internal '') || die "the Caddyfile does not adapt under internal"
! jq -e '[.. | objects | select(.provider?.name? == "acmedns")] | length > 0' <<<"${json}" >/dev/null ||
  die "under internal, an issuer still hands its check to acmedns"
echo "${0##*/}: under internal, no acmedns"

sudo grep -qx 'CERT_WILDCARD=' /etc/dotdash/caddy.env || die "caddy.env does not hold an empty CERT_WILDCARD: $(sudo cat /etc/dotdash/caddy.env)"
echo "${0##*/}: the installed release renders no wildcard for a two-label domain"
