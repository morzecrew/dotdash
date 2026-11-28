# shellcheck shell=sh disable=SC2034 # the scripts that source this use them
# Sourced by relay-entry.sh and facts.sh: what devices need to reach this relay,
# derived once. $1, when given, is the address devices reach it at; else
# entry_host, else, under own-site, the relay's domain.
# The keys are public halves and a short id, as in any link.
: "${SITE:?set site}"
# The parameter's default, with the own-site profile off; the profile sets
# SITE to the relay's domain.
[ "${SITE}" != none ] || { echo "set site, or use the own-site profile with a domain of the relay's own" >&2; exit 1; }
host=${1:-${ENTRY_HOST:-none}}
[ "$host" != none ] || [ "${OWN_SITE:-}" != true ] || host=$SITE
[ "$host" != none ] || { echo "set entry_host to the address devices reach this relay at (its IP without a domain), or give it after --" >&2; exit 1; }

pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
sid=$(cat /run/secrets/reality_short_id)
# name and nonce: each server derives this relay's id from them (and its own
# relay_seed), and devices' links through it carry the name. The relay/1
# line is split on spaces, so letters, digits, dots, dashes and underscores
# alone; none was the unset name of the release before.
name=${NAME:-}
case $name in
  '' | none | ?????????????????????????* | *[!A-Za-z0-9._-]*)
    echo "name is not 1 to 24 letters, digits, dots, dashes or underscores: '$name'; set one: sudo morzer config set name=<name>" >&2
    exit 1 ;;
esac
nonce=$(cat /run/secrets/nonce)
case $nonce in
  ????????????????) case $nonce in *[!0-9a-f]*) nonce= ;; esac ;;
  *) nonce= ;;
esac
[ -n "$nonce" ] || { echo "the nonce secret is not 16 lowercase hex characters: sudo morzer secret generate nonce makes one, and a new relay id on every server" >&2; exit 1; }

# own-site: this relay serves its own site under SITE, which fetches devices'
# subscriptions from the server and routes the XHTTP path to Xray, so
# client-config gives each device that URL and an XHTTP link through it. Its
# certificate is in Caddy's data, where xray.json.tmpl finds it for
# Hysteria2 (mounted at /caddy-data for facts and entry-check).
path= cert_file=
if [ "${OWN_SITE:-}" = true ]; then
  path=$(cat /run/secrets/xhttp_path)
  case ${CERT_ISSUER:-acme} in internal) dir=local ;; *) dir=acme-v02.api.letsencrypt.org-directory ;; esac
  cert=$SITE
  case ${CERT_ISSUER:-acme}:$SITE in acme-dns:*.*.*) cert=wildcard_.${SITE#*.} ;; esac
  cert_file=/caddy-data/caddy/certificates/$dir/$cert/$cert.crt
fi
# mkcp: this relay serves mKCP too, so client-config gives each device an mKCP
# link through it. With kcp_open=quic the device's link carries the matching
# finalmask noise mask.
kcp_seed=
[ -z "${KCP_PORT:-}" ] || kcp_seed=$(cat /run/secrets/kcp_seed)
# hysteria2: this relay serves Hysteria2 too, under its own site's
# certificate, so client-config gives each device a Hysteria2 link through it.
hy2_port=${HYSTERIA2_PORT:-}
# cdn_hosts: local CDNs in front of this relay's own site, each fetching
# from https://SITE with Host set to it, so client-config gives each device an
# XHTTP link through each, shaped as for the server's cdn_hosts.
cdn=$(printf '%s' "${CDN_HOSTS:-none}" | tr -d ' ')
case $cdn in
  none | '') cdn= ;;
  ,* | *, | *,,* | *[!A-Za-z0-9.,-]*)
    echo "cdn_hosts is not <name>[,<name>]: $cdn; leaving it out" >&2; cdn= ;;
  *) [ "${OWN_SITE:-}" = true ] ||
       { echo "cdn_hosts needs the own-site profile, whose site a CDN fetches from; leaving it out" >&2; cdn=; } ;;
esac
# http_origin_host (set under the http-origin profile): the names devices
# reach a rented CDN at, comma-separated, which fetches this relay in plain
# HTTP through Caddy's door; client-config gives each device an XHTTP link
# through each, on the CDN path below with smaller uploads. A name may carry
# a path, <name>/<path>, which its links take instead: a gateway's own, which
# it turns back into the CDN path on its way here.
origin=$(printf '%s' "${HTTP_ORIGIN_HOST:-none}" | tr -d ' ')
ok=true
case $origin in none | '' | ,* | *, | *,,* | *[!A-Za-z0-9.,/_~-]*) ok=false ;; esac
[ "$ok" = false ] || for o in $(printf '%s' "$origin" | tr ',' ' '); do
  oh=${o%%/*}
  case $oh in '' | .* | *. | *..* | *[!A-Za-z0-9.-]*) ok=false ;; esac
  case ${o#"$oh"} in *[!A-Za-z0-9._~/-]*) ok=false ;; esac
done
case $origin in
  none | '') origin= ;;
  *) [ "$ok" = true ] || { echo "http_origin_host is not <name>[/<path>], comma-separated: $origin; leaving it out" >&2; origin=; } ;;
esac
case $origin in
  '') ;;
  *) [ "${OWN_SITE:-}" = true ] ||
       { echo "http_origin_host needs the own-site profile, whose Caddy is the door; leaving it out" >&2; origin=; } ;;
esac
# The CDNs' own XHTTP path, which their links take in place of the one above,
# with the settings of the CDN inbound. A relay that names none is fetched by
# a server from before it by the one above, as before.
# The http-origin profile's door takes it too (HTTP_ORIGIN_PORT is set under
# that profile alone), so the settings it prints for the CDN's form come
# before the CDN has given a name for http_origin_host.
cdn_path=
[ -z "$cdn$origin${HTTP_ORIGIN_PORT:-}" ] || cdn_path=$(cat /run/secrets/cdn_xhttp_path)
# cdn_only: devices get the CDN links alone, so this relay's own address
# reaches none of them; with no CDN that would be no link at all.
only=
if [ "${CDN_ONLY:-false}" = true ]; then
  [ -n "$cdn$origin" ] || { echo "cdn_only needs cdn_hosts or http_origin_host, with the own-site profile: devices would get no link through this relay" >&2; exit 1; }
  only=" cdn-only"
fi
