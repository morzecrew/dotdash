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

# own-site: this relay serves its own site under SITE, which fetches devices'
# subscriptions from the server and routes the XHTTP path to Xray, so
# client-config gives each device that URL and an XHTTP link through it.
path=
[ "${OWN_SITE:-}" != true ] || path=$(cat /run/secrets/xhttp_path)
# mkcp: this relay serves mKCP too, so client-config gives each device an mKCP
# link through it. With kcp_open=quic the device's link carries the matching
# finalmask noise mask.
kcp_seed=
[ -z "${KCP_PORT:-}" ] || kcp_seed=$(cat /run/secrets/kcp_seed)
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
