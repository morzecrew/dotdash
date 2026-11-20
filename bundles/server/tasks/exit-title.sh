#!/bin/sh
# The subscriptions' name in the apps that read one: this server's IPv4 exit,
# as the sites devices visit see it, after its country's flag
# ("<flag> 203.0.113.7"), in place of this server's domain. Written base64 to
# /exit/title, which Caddy sends as Profile-Title on every device's
# subscription (caddy/Caddyfile).
#
# Asked through Xray's probe inbound, as exit-check.sh asks, at start and
# every ten minutes, so an exit that changed (a line failed over) shows at a
# device's next refresh. Nothing is written until a check answers, and one
# that fails keeps the last title. With the subscription parameter off, it
# asks nothing.
set -u
[ "${SUBSCRIPTION:-false}" = true ] || exec sleep 2147483647
ipv4_url=${EXIT_IPV4_URL:-http://api4.ipify.org}
info_url=${EXIT_INFO_URL:-http://ipinfo.io}
# busybox wget reads http_proxy, for https URLs too: without it, it would
# report this server's own address.
export http_proxy=http://127.0.0.1:10809

flag() { # <country code>: its flag, the two regional indicator letters, in UTF-8
	# shellcheck disable=SC2046 # one byte value a word
	set -- $(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | od -An -tu1)
	# shellcheck disable=SC2059 # the format is the bytes
	printf "\\360\\237\\207\\$(printf %o $(($1 + 101)))\\360\\237\\207\\$(printf %o $(($2 + 101)))"
}

while :; do
	ip=$(wget -q -O - -T 10 "$ipv4_url" 2>/dev/null | tr -d ' \r\n')
	if printf '%s' "$ip" | grep -Eqx '[0-9]{1,3}(\.[0-9]{1,3}){3}'; then
		title=$ip
		cc=$(wget -q -O - -T 10 "$info_url/$ip/country" 2>/dev/null | tr -d ' \r\n')
		case $cc in [A-Za-z][A-Za-z]) title="$(flag "$cc") $ip" ;; esac
		if [ "$(cat /exit/title 2>/dev/null)" != "$(printf '%s' "$title" | base64 | tr -d '\n')" ]; then
			printf '%s' "$title" | base64 | tr -d '\n' >/exit/title.new && mv /exit/title.new /exit/title
			echo "exit-title: ${title}"
		fi
	fi
	sleep 600
done
