#!/bin/sh
# Prints what a device needs to use this machine's proxy port: its SOCKS5 and
# HTTP proxy URLs, with proxy_user and proxy_password once the port is
# published beyond 127.0.0.1. $1 is the address devices reach this machine at.
# Then the output is a credential: anyone holding it can use the port.
set -eu
: "${LISTEN:?}" "${PORT:?}" "${PROXY_USER:?}"

if [ "$LISTEN" = 127.0.0.1 ]; then
  cat <<EOF
The port is on 127.0.0.1, for this machine alone, and asks for nothing:
socks5h://127.0.0.1:${PORT}
http://127.0.0.1:${PORT}

For other devices: sudo morzer config set listen=0.0.0.0, then run this again.
EOF
  exit 0
fi

# Published on one address, that is where devices connect; on 0.0.0.0, only
# the operator knows which of this machine's addresses they reach.
case $LISTEN in
  0.0.0.0) host=${1:-"<this machine's address>"} ;;
  *) host=${1:-$LISTEN} ;;
esac
pass=$(cat /run/secrets/proxy_password)
cat <<EOF
For devices on the network (as secret as a password):
socks5h://${PROXY_USER}:${pass}@${host}:${PORT}
http://${PROXY_USER}:${pass}@${host}:${PORT}

Or, for an app that asks for them apart: server ${host}, port ${PORT},
username ${PROXY_USER}, password ${pass}.

A new password, which every device then needs: sudo morzer secret rotate
proxy_password, then run this again.
EOF
