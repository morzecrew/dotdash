#!/bin/sh
# Prints the server/1 line the relay named in $1, by its relay/1 line in
# relays, keeps in its servers secret for this server group:
#
#   server/1 <name> <host>[,<host>...] <port> <public key> <short id> <encryption> <relay id> [xr=<port>,<path>]
#
# the group's name (the name parameter), every server sharing these keys
# (servers), the port they take REALITY on, their keys as devices' links
# carry them, and the relay's id here, which the image derives from
# relay_seed and the relay's name and nonce, as Xray's REALITY inbounds let
# it in (xray.json.tmpl); xr= under the xhttp-reality profile, its port and
# path. The id is the relay's way in, so the line is as secret as a link.
#
# A relay of the release before has no relay/1 line: named as its client in
# vless_clients, it gets what it did, the init command and its copy of every
# device, which is every device's credentials.
set -eu
# shellcheck source=common.sh
. /task/common.sh
want=${1:?name the relay, as its relay/1 line in relays names it: relay-config -- <relay>}

line=$(printf '%s\n' "${RELAYS:-}" | awk -v r="$want" '$1 == "relay/1" && $2 == r { print; exit }')
if [ -n "$line" ]; then
  [ "$group" != none ] || {
    echo "this server group has no name: set one first, the same on every server in servers (sudo morzer config set name=<name>)" >&2
    exit 1; }
  # shellcheck disable=SC2086 # one field per word
  set -f && set -- $line
  # The image checks the name and nonce, and refuses a seed of another shape.
  id=$(/opt/xray/xray-entrypoint relay-id /run/secrets/relay_seed "$2" "$3")
  xr=
  [ -z "${XHTTP_REALITY_PORT:-}" ] || xr=" xr=${XHTTP_REALITY_PORT},$(cat /run/secrets/xhttp_path)"
  echo "server/1 ${group} $(server_list | tr '\n' ',' | sed 's/,$//') ${HTTPS_PORT}" \
    "$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key) $(cat /run/secrets/reality_short_id)" \
    "$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed) ${id}${xr}"
  echo "On the relay $2: sudo EDITOR=nano morzer secret edit servers, and add this line there, in place of any line of ${group}'s." >&2
  exit 0
fi

id=
while read -r line_id name _ || [ -n "${line_id:-}" ]; do
  case $line_id in '' | '#'*) continue ;; esac
  [ "$want" = "${name:-}" ] && { id=$line_id; break; }
done </run/secrets/vless_clients
[ -n "$id" ] || { echo "no relay/1 line in relays names '$want', nor does a client in vless_clients" >&2; exit 1; }
# Every server sharing these keys (the servers parameter), self as this one:
# the relay uses whichever answers fastest.
servers=$(server_list | tr '\n' ',' | sed 's/,$//')

cat <<EOF
For a relay of the release before, which has no relay/1 line: a relay of
this one prints that line with relay-entry, which goes into relays, and then
gets its server/1 line here, relay-config -- <its name>.

On the relay machine, inside the restricted network (scripts/bootstrap.sh
installs what it needs). init trusts the signing key the release ships, as for
dotdash itself.

Devices send the name of a site, and anyone probing the relay meets it. Best,
a site of the relay's own: a domain whose DNS points at the relay, port 80
open for its certificate, and in place of --set site below:
  --domain relay.example.net --profile own-site
Or a site next to the relay, in its own network, not a big name, on TLS 1.3
and HTTP/2, as below; its DNS points elsewhere, which an observer can compare.

sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-relay:0.18.0 \\
  --recovery-recipient age1… \\
  --set site=<a site next to the relay> \\
  --set dotdash_servers=${servers} --set dotdash_port=${HTTPS_PORT} \\
  --set dotdash_public_key=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
sudo morzer secret set dotdash_id <<'END'
${id}
END
sudo morzer secret set dotdash_encryption <<'END'
$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
END
sudo morzer secret set dotdash_short_id <<'END'
$(cat /run/secrets/reality_short_id)
END
sudo morzer secret set vless_clients <<'END'
EOF
# Every device but the relay's own client, which it uses itself.
copy=$(while read -r line_id name rest || [ -n "${line_id:-}" ]; do
  [ "${name:-}" = "$want" ] && continue
  echo "${line_id}${name:+ $name}${rest:+ $rest}"
done </run/secrets/vless_clients)
printf '%s\n' "$copy"
# How many devices that copy lets in, and the first 8 hex characters of the
# sha256 of their ids, sorted, one per line: the relay's relay-entry and
# facts say the same of its own copy, and differ while it is stale.
ids=$(printf '%s\n' "$copy" | awk '$1 !~ /^#/ && NF { print $1 }' | LC_ALL=C sort)
digest=$(printf '%s' "$ids" | awk 'NF' | sha256sum | cut -c1-8)
cat <<EOF
END
sudo morzer apply
sudo morzer task run relay-entry --output -- <the relay's domain, or its IP without one>

Add the line relay-entry prints to this server's relays parameter (sudo
morzer config edit relays), then send devices their links again; subscriptions
pick it up by themselves. A device added to or deleted from vless_clients here has to
change in the relay's copy too: set it there again from this output.
The devices this copy lets in: $(printf '%s' "$ids" | awk 'NF' | wc -l | tr -d ' '), digest ${digest}. relay-entry on
the relay prints the same of its own copy once it is this one.
EOF
# Set under the xhttp-reality profiles only, as for client-config.
[ -n "${XHTTP_REALITY_PORT:-}" ] || exit 0
cat <<EOF

This server also serves XHTTP with REALITY: the relay can reach it that way,
its connections reused across devices, sooner to a page's first byte for
about twice the CPU on both machines. The path goes first: the link it
replaces reads none, and a link without it fails the relay's health check:
sudo morzer secret set dotdash_xhttp_path <<'END'
$(cat /run/secrets/xhttp_path)
END
sudo morzer config set dotdash_link=xhttp-reality dotdash_xhttp_reality_port=${XHTTP_REALITY_PORT}
EOF
