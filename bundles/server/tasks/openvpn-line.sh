#!/bin/sh
# Prints the upstreams line for an OpenVPN exit from its client config ($1, a
# task input): openvpn:// and the config, gzipped and base64url-encoded, which
# the openvpn profile's client decodes back (OPENVPN_UPSTREAMS,
# platform-images). Keys and any login go inline in the config, as the client
# refuses a login it would have to ask for. The output holds the keys, so it
# is a credential.
set -eu
conf=${1:?give the client config: task run openvpn-line --input conf=<file>}
tr -d '\r' <"$conf" | grep -q '^[[:space:]]*remote[[:space:]]' ||
  { echo "openvpn-line: the file has no remote line, so it names no server" >&2; exit 1; }
if tr -d '\r' <"$conf" | grep -q '^[[:space:]]*auth-user-pass[[:space:]]*$' &&
  ! tr -d '\r' <"$conf" | grep -q '^[[:space:]]*<auth-user-pass>[[:space:]]*$'; then
  echo "openvpn-line: the file asks for a login (auth-user-pass) and holds none: add <auth-user-pass>, the user and the password on two lines, then </auth-user-pass>" >&2
  exit 1
fi
printf 'openvpn://%s\n' "$(gzip -9c "$conf" | base64 | tr -d '\n=' | tr '+/' '-_')"
