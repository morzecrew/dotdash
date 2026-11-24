#!/bin/sh
# The openflux profile's client: OpenFlux's SOCKS5 on port 1080 of the
# compose network, which Xray's balancer falls back to when every dotdash
# link fails its probe (templates/config.json.tmpl). It reaches this device's
# OpenFlux exit on a dotdash server over the link in the openflux_link
# secret, as the server's openflux-link task prints it: "<device> <link>", or
# the link alone.
#
# OpenFlux's CLI runs from a config file, not a link, so the link is read
# with the binary's own --parse-link and written out as one: the key in
# /tmp/key, the rest in /tmp/client.conf, both on tmpfs.
set -eu
umask 077
say() { echo "openflux: $*"; }

link=$(sed -n 's|.*\(openflux://v1/[^[:space:]]*\).*|\1|p' /run/secrets/openflux_link | sed -n 1p)
if [ -z "$link" ]; then
  say "openflux_link holds no openflux:// link: idle, and nothing to fall back to"
  trap 'exit 0' TERM INT
  while :; do sleep 3600 & wait $! || true; done
fi
# An error is JSON with a code and no key; the profile is JSON with the key.
json=$(openflux --parse-link "$link" 2>&1) || { say "the link in openflux_link does not read: $json"; exit 1; }

# field <name>: the last "<name>":"<value>" in the JSON, its \u escapes of
# &, < and > undone (Go writes those three escaped).
field() {
  printf '%s' "$json" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" |
    sed -e 's/\\u0026/\&/g' -e 's/\\u003c/</g' -e 's/\\u003e/>/g'
}
field secret >/tmp/key
[ -s /tmp/key ] || { say "the link in openflux_link holds no key"; exit 1; }
{
  printf '[Interface]\nRole = client\nInbound = socks5\nSocks5 = 0.0.0.0:1080\n'
  printf 'EncryptionKeyFile = /tmp/key\nCookieStore = /tmp/cookies.json\nSessionContext = %s\n' "$(field context)"
} >/tmp/client.conf

n=0
transports=$(printf '%s' "$json" | sed -n 's/.*"transports":\[{\(.*\)}\].*/\1/p' | sed 's/},{/\n/g')
while IFS= read -r t; do
  [ -n "$t" ] || continue
  json="{$t}"
  type=$(field type) url=$(field url) dial=$(field dial)
  [ -n "$type" ] || continue
  n=$((n + 1))
  printf '\n[Transport %s-%s]\nType = %s\nPriority = 50\n' "$type" "$n" "$type" >>/tmp/client.conf
  if [ -n "$dial" ]; then
    printf 'Dial = %s\n' "$dial" >>/tmp/client.conf
  else
    printf 'URL = %s\n' "$url" >>/tmp/client.conf
  fi
  say "transport $n: $type"
done <<EOF
$transports
EOF
[ "$n" -gt 0 ] || { say "the link in openflux_link names no transport"; exit 1; }
exec openflux --config /tmp/client.conf
