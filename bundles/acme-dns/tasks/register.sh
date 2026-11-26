#!/bin/sh
# Registers one parent domain with acme-dns. Prints the CNAME its DNS host
# needs, then the acme_dns secret of each server or relay under it, as one
# line of JSON. Every machine under the parent shares the registration.
set -eu
parent=${1:?give the parent domain the wildcard is over, such as s.example.com for x7k2.s.example.com}
parent=${parent%.}
# The API takes registrations only while the registration parameter is on.
[ "${REGISTRATION:-false}" = true ] || {
  echo "registration is off: sudo morzer config set registration=true, run register again, then sudo morzer config set registration=false" >&2
  exit 1
}

url=https://$ZONE
[ "$API_TLS" = none ] && url=http://$ZONE:443
if ! reg=$(wget -q -O- --post-data= "$url/register"); then
  echo "acme-dns did not register at $url: check \`morzer doctor\`" >&2
  exit 1
fi

# acme-dns answers flat JSON with no spaces.
field() { printf '%s' "$reg" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
fulldomain=$(field fulldomain)
[ -n "$fulldomain" ] || { echo "acme-dns answered no registration" >&2; exit 1; }

echo "At ${parent}'s DNS host:"
echo
echo "_acme-challenge.${parent}.  CNAME  ${fulldomain}."
echo
echo "On each server or relay under ${parent}: sudo morzer secret set acme_dns, then this line:"
echo
printf '{"username": "%s", "password": "%s", "subdomain": "%s", "server_url": "%s"}\n' \
  "$(field username)" "$(field password)" "$(field subdomain)" "$url"
echo
echo "With every parent registered, close registration again: sudo morzer config set registration=false"
