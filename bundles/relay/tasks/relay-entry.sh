#!/bin/sh
# Prints this relay's relay/1 line, the one line every dotdash server group
# it serves keeps in its relays parameter, and how a dotdash-canary inside
# the restricted network checks the relay: the one kind of check that sees
# what devices see. The address devices reach this machine at comes after
# --, or from entry_host (entry.sh).
#
#   relay/1 <name> <nonce> <host> <site> <public key> <short id> <encryption> [xhttp=<path>]
#     [kcp=<port>,<header>,<seed>[,quic]] [hy2=<port>] [cdn=<host>,...] [cdnpath=<path>]
#     [origin=<host>[/<path>],...] [cdn-only]
#
# The same line for every server: nothing in it depends on one. A server
# derives this relay's id from its name and nonce, and its own relay_seed.
set -eu
# shellcheck source=entry.sh
. /task/entry.sh

kcp=
if [ -n "$kcp_seed" ]; then
  kcp=" kcp=${KCP_PORT},${KCP_HEADER:-dtls},${kcp_seed}"
  [ "${KCP_OPEN:-none}" != quic ] || kcp="${kcp},quic"
fi

cat <<EOF
On each dotdash server group this relay is to carry devices to, add this
line to the relays parameter (sudo morzer config edit relays):
relay/1 ${name} ${nonce} ${host} ${SITE} ${pbk} ${sid} ${enc}${path:+ xhttp=$path}${kcp}${hy2_port:+ hy2=$hy2_port}${cdn:+ cdn=$cdn}${cdn_path:+ cdnpath=$cdn_path}${origin:+ origin=$origin}${only}

Then the server/1 line that server prints for this relay goes here, one line
per server group, in place of any line of that group's:
sudo morzer task run relay-config --output -- ${name}   # on the server
sudo EDITOR=nano morzer secret edit servers               # here
sudo morzer task run servers --output                     # here, within a minute

A dotdash-canary checks this relay as it checks a server, without the xhttp
profiles, as a device of one server group behind it, with that device's id:
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
