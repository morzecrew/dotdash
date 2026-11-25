#!/bin/sh
# Prints this relay's line for the dotdash server's relays parameter, and how a
# dotdash-canary inside the restricted network checks the relay: the one kind of check
# that sees what devices see. The address devices reach this machine at comes
# after --, or from entry_host (entry.sh).
set -eu
# shellcheck source=entry.sh
. /task/entry.sh

own=${path:+ own-site $path}
# Last on the line, where a server from before them reads no field: kcp= with
# a fourth field naming the opener under kcp_open=quic, hy2=, cdn= and the
# CDNs' path as cdnpath=, origin=, then name=.
kcp=
if [ -n "$kcp_seed" ]; then
  kcp=" kcp=${KCP_PORT},${KCP_HEADER:-dtls},${kcp_seed}"
  [ "${KCP_OPEN:-none}" != quic ] || kcp="${kcp},quic"
fi

cat <<EOF
On the dotdash server, add this line to the relays parameter (sudo morzer
config edit relays):
${host} ${SITE} ${pbk} ${sid} ${enc}${own}${kcp}${hy2_port:+ hy2=$hy2_port}${cdn:+ cdn=$cdn}${cdn_path:+ cdnpath=$cdn_path}${origin:+ origin=$origin}${only}${name:+ name=$name}

A dotdash-canary checks this relay as it checks the server, without the xhttp
profiles, with the dotdash_id of any device on the relay:
sudo morzer config set dotdash_server=${SITE} dotdash_address=${host} dotdash_port=443 dotdash_public_key=${pbk}
sudo morzer secret set dotdash_encryption <<'END'
${enc}
END
sudo morzer secret set dotdash_short_id <<'END'
${sid}
END
EOF
[ -z "$hy2_port" ] || cat <<EOF
and Hysteria2 beside REALITY, through the relay's own site's certificate:
sudo morzer config set installation.profile=hysteria2 dotdash_hysteria2_port=${hy2_port}
EOF
[ -z "${HTTP_ORIGIN_PORT:-}" ] || cat <<EOF

The http-origin door: a rented CDN fetches this relay in plain HTTP on port
${HTTP_ORIGIN_PORT} (http_origin_port), from the addresses in http_origin_from. Where it
asks for the node's xhttpSettings, give it these, which devices' links through
it match:
{"path": "/${cdn_path}", "mode": "packet-up", "extra": {"uplinkHTTPMethod": "GET", "uplinkDataPlacement": "header", "uplinkChunkSize": 4096, "scMaxEachPostBytes": 4096, "scMinPostsIntervalMs": 10}}
EOF
[ -n "$origin" ] || [ -z "${HTTP_ORIGIN_PORT:-}" ] || cat <<EOF
Then set http_origin_host to the name the CDN gives devices (several,
comma-separated, where it gives more than one, each followed by the path
it gives, /<path>, where that is not the one above), and print this line
again: devices get links through the door only once it ends in origin=.
EOF
