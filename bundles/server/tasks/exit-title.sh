#!/bin/sh
# The subscriptions' name in the apps that read one: this server's IPv4 exit,
# as the sites devices visit see it, after its country's flag
# ("<flag> 203.0.113.7"), in place of this server's domain. Written base64 to
# /exit/title, which Caddy sends as Profile-Title on every device's
# subscription (caddy/Caddyfile).
#
# Asked through Xray's title-ip and title-info inbounds, each a forward to
# its URL's host, as client traffic leaves, at start and every ten minutes, so an exit that changed (a line failed over) shows at a
# device's next refresh. Nothing is written until a check answers, and one
# that fails keeps the last title and is asked again in 15 s: Xray, restarted
# with this, may not listen yet. With the subscription parameter off, it asks
# nothing. With direct=false it asks nothing either, and takes away the title
# it wrote: a direct line in the upstreams makes the exit this server's own
# address, which direct=false keeps from devices.
set -u
[ "${SUBSCRIPTION:-false}" = true ] || exec sleep 2147483647
[ "${DIRECT:-true}" != false ] || { rm -f /exit/title; exec sleep 2147483647; }
ipv4_url=${EXIT_IPV4_URL:-http://api4.ipify.org}
info_url=${EXIT_INFO_URL:-http://ipinfo.io}
# Its network has no other way out: each request goes to Xray's forward for
# its URL's host, named in Host as the URL names it.
get() { # <url> <forward port> [path suffix]: the body
	rest=${1#http://}
	hostport=${rest%%/*}
	path=/
	case $rest in */*) path=/${rest#*/} ;; esac
	[ -z "${3:-}" ] || path=${path%/}$3
	wget -q -O - -T 10 --header "Host: ${hostport}" "http://xray:$2${path}" 2>/dev/null
}

flag() { # <country code>: its flag, the two regional indicator letters, in UTF-8
	# shellcheck disable=SC2046 # one byte value a word
	set -- $(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | od -An -tu1)
	# shellcheck disable=SC2059 # the format is the bytes
	printf "\\360\\237\\207\\$(printf %o $(($1 + 101)))\\360\\237\\207\\$(printf %o $(($2 + 101)))"
}

while :; do
	wait=15
	ip=$(get "$ipv4_url" 10812 | tr -d ' \r\n')
	if printf '%s' "$ip" | grep -Eqx '[0-9]{1,3}(\.[0-9]{1,3}){3}'; then
		wait=600
		title=$ip
		cc=$(get "$info_url" 10813 "/$ip/country" | tr -d ' \r\n')
		case $cc in [A-Za-z][A-Za-z]) title="$(flag "$cc") $ip" ;; esac
		if [ "$(cat /exit/title 2>/dev/null)" != "$(printf '%s' "$title" | base64 | tr -d '\n')" ]; then
			printf '%s' "$title" | base64 | tr -d '\n' >/exit/title.new && mv /exit/title.new /exit/title
			echo "exit-title: ${title}"
		fi
	fi
	sleep "$wait"
done
