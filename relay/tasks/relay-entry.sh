#!/bin/sh
# Prints this relay's line for the dotdash server's relays secret, given the
# address devices reach this machine at, and how a dotdash-canary inside the
# country checks the relay: the one kind of check that sees what devices see.
# The keys are public halves and a short id, as in any link.
set -eu
: "${SITE:?set site}"
# The parameter's default, with the own-site profile off; the profile sets
# SITE to the relay's domain.
[ "${SITE}" != none ] || { echo "set site, or use the own-site profile with a domain of the relay's own" >&2; exit 1; }
host=${1:?give the address devices reach this relay at: relay-entry -- <IP or name>}

pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
sid=$(cat /run/secrets/reality_short_id)

# own-site: this relay serves its own site under SITE, which fetches devices'
# subscriptions from the server and routes the XHTTP path to Xray, so
# client-config gives each device that URL and an XHTTP link through it.
if [ "${OWN_SITE:-}" = true ]; then own=" own-site $(cat /run/secrets/xhttp_path)"; else own=; fi
# mkcp: this relay serves mKCP too, so client-config gives each device an mKCP
# link through it. Last on the line, where a server from before it reads no
# field. With kcp_open=quic a fourth field names the opener, so the device's
# link carries the matching finalmask noise mask.
if [ -n "${KCP_PORT:-}" ]; then
  kcp=" kcp=${KCP_PORT},${KCP_HEADER:-dtls},$(cat /run/secrets/kcp_seed)"
  [ "${KCP_OPEN:-none}" != quic ] || kcp="${kcp},quic"
else kcp=; fi

cat <<EOF
On the dotdash server, add this line to the relays parameter (sudo morzer
config edit relays):
${host} ${SITE} ${pbk} ${sid} ${enc}${own}${kcp}

A dotdash-canary checks this relay as it checks the server, without the xhttp
profiles, with the vless_id of any device on the relay:
sudo morzer config set server=${SITE} address=${host} port=443 reality_public_key=${pbk}
sudo morzer secret set vless_encryption <<'END'
${enc}
END
sudo morzer secret set reality_short_id <<'END'
${sid}
END
EOF
