#!/bin/sh
# Prints what a dotdash-relay machine needs to carry devices on to this server
# as the client named in $1: the init command and its secrets, among them the
# devices it lets in. The output is every device's credentials.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
want=${1:?name the client the relay uses, as in vless_clients: relay-config -- <name>}

id=
while read -r line_id name _ || [ -n "${line_id:-}" ]; do
  case $line_id in '' | '#'*) continue ;; esac
  [ "$want" = "${name:-}" ] && { id=$line_id; break; }
done </run/secrets/vless_clients
[ -n "$id" ] || { echo "no client named '$want' in vless_clients" >&2; exit 1; }
# Every server sharing these keys (the servers parameter), self as this one:
# the relay uses whichever answers fastest.
servers=$(printf '%s\n' "${SERVERS:-self}" | tr ',' '\n' | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e "s/^self\$/${DOMAIN}/" | tr '\n' ',' | sed 's/,$//')

cat <<EOF
On the relay machine, inside the country (scripts/bootstrap.sh installs what it
needs). The signing key is the dotdash repository's MINISIGN_RELEASE_PUBKEY
variable, as for dotdash itself. For site, pick a site in the relay's own
network, not a big name, that speaks TLS 1.3 and HTTP/2: devices send its name,
and anyone probing the relay gets its real handshake.

sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-relay:stable \\
  --require-signature --signing-key "\$MINISIGN_RELEASE_PUBKEY" --recovery-recipient age1… \\
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
while read -r line_id name rest || [ -n "${line_id:-}" ]; do
  [ "${name:-}" = "$want" ] && continue
  echo "${line_id}${name:+ $name}${rest:+ $rest}"
done </run/secrets/vless_clients
cat <<EOF
END
sudo morzer apply
sudo morzer task run relay-entry -- <the address devices reach the relay at>

Add the line relay-entry prints to this server's relays parameter (sudo
morzer config edit relays), then send devices their links again; subscriptions
pick it up by themselves. A device added to or deleted from vless_clients here has to
change in the relay's copy too: set it there again from this output.
EOF
