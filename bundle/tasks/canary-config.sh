#!/bin/sh
# Prints what a dotdash-canary machine needs to act as the client named in $1:
# the init command and its secrets. The output is that client's credentials.
set -eu
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
want=${1:?name the client the canary uses, as in vless_clients: canary-config -- <name>}

id=
while read -r line_id name _ || [ -n "${line_id:-}" ]; do
  case $line_id in '' | '#'*) continue ;; esac
  [ "$want" = "${name:-}" ] && { id=$line_id; break; }
done </run/secrets/vless_clients
[ -n "$id" ] || { echo "no client named '$want' in vless_clients" >&2; exit 1; }

cat <<EOF
On the canary machine (scripts/bootstrap.sh installs what it needs). The
signing key is the dotdash repository's MINISIGN_RELEASE_PUBKEY variable, as
for dotdash itself, and the recovery recipient can be dotdash's: with it,
backups carry this machine's identity, which unattended updates need. Add
--profile xhttp to check the XHTTP path too.

sudo morzer init --product dotdash-canary --release oci://ghcr.io/morzecrew/dotdash-canary:stable \\
  --require-signature --signing-key "\$MINISIGN_RELEASE_PUBKEY" --recovery-recipient age1… \\
  --set server=${DOMAIN} --set address=${DOMAIN} --set port=${HTTPS_PORT} \\
  --set reality_public_key=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
sudo morzer secret set vless_id <<'END'
${id}
END
sudo morzer secret set vless_encryption <<'END'
$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
END
sudo morzer secret set reality_short_id <<'END'
$(cat /run/secrets/reality_short_id)
END
sudo morzer secret set xhttp_path <<'END'
$(cat /run/secrets/xhttp_path)
END
sudo morzer apply
EOF
# Set under the xhttp-reality profiles only, as for client-config.
[ -n "${XHTTP_REALITY_PORT:-}" ] || exit 0
cat <<EOF

This server also serves XHTTP with REALITY: init with --profile xhttp-reality
--set xhttp_reality_port=${XHTTP_REALITY_PORT}, in place of --profile xhttp, to
check that path beside REALITY.
EOF
