#!/bin/sh
# Prints the exits the sites your clients visit see: the IPv4 and the IPv6
# address the upstream leaves from, each with its network (ASN) and country,
# fetched through Xray as client traffic is. Changes nothing, IPv6 included.
#
#   exit-check.sh [ipv4-url ipv6-url info-url]
#
# The URLs answer with the caller's address alone (one has an A record only,
# the other AAAA only), and info-url/<address>/org and /country with that
# address's network and country. They are plain HTTP: this task runs in Xray's
# network namespace with busybox wget, which asks a proxy for an https URL in a
# form Xray refuses; an exit address is public anyway.
set -u
ipv4_url=${1:-http://api4.ipify.org}
ipv6_url=${2:-http://api6.ipify.org}
info_url=${3:-http://ipinfo.io}
# Xray's probe inbound. busybox wget reads http_proxy, for https URLs too, and
# never https_proxy: without this, it would report this server's own address.
export http_proxy=http://127.0.0.1:10809

# <url>: the body, and status 0; or the reason, and status 1. The container
# is read-only, so the two are told apart by wget's status, not a temp file.
get() {
	if out=$(wget -q -O - -T 10 "$1" 2>&1); then
		printf '%s' "$out" | head -c 512
	else
		printf '%s' "$out" | sed -e 's/^wget: //' -e 's/^server returned error: //' | head -n1
		return 1
	fi
}

exit_of() { # <family> <url> <pattern>: sets addr, org, country, why
	addr= org= country= why=
	if ! body=$(get "$2"); then
		why=${body:-no answer}
		return 1
	fi
	addr=$(printf '%s' "$body" | tr -d ' \r\n')
	if [ -z "$addr" ]; then
		why="$2 answered nothing"
		return 1
	fi
	if ! printf '%s' "$addr" | grep -Eq "$3"; then
		why="$2 answered something that is not an $1 address: $(printf '%s' "$addr" | head -c 60)"
		addr=
		return 1
	fi
	if org=$(get "$info_url/$addr/org"); then
		org=$(printf '%s' "$org" | tr -d '\r\n')
	else
		org="network unknown ($org)"
	fi
	country=$(get "$info_url/$addr/country" | tr -d ' \r\n') || country="??"
}

if exit_of IPv4 "$ipv4_url" '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
	v4=$addr v4org=$org v4cc=$country
	echo "IPv4 exit  $v4  $v4org  $v4cc"
else
	v4= v4why=$why
	echo "IPv4 exit  none: $v4why"
fi
if exit_of IPv6 "$ipv6_url" '^[0-9A-Fa-f:]+:[0-9A-Fa-f:]*$'; then
	v6=$addr v6org=$org v6cc=$country
	echo "IPv6 exit  $v6  $v6org  $v6cc"
else
	v6= v6why=$why
	echo "IPv6 exit  unavailable: $v6why"
fi
case ${RESOLVE:-gateway} in
gateway) echo "Names    resolved here over ${DNS_RESOLVER:-DoH}, through the upstream: it is handed addresses only" ;;
*) echo "Names    resolved by the upstream, which sees every hostname (resolve=upstream)" ;;
esac
echo

asn() { printf '%s' "$1" | sed -n 's/^\(AS[0-9][0-9]*\).*/\1/p'; }
if [ -n "$v4" ] && [ -n "$v6" ]; then
	a4=$(asn "$v4org") a6=$(asn "$v6org")
	if [ -z "$a4" ] || [ -z "$a6" ]; then
		echo "Both exits answer, but their networks could not both be looked up at $info_url to compare them."
	elif [ "$a4" = "$a6" ]; then
		echo "Both exits are in $a4 ($v4cc, $v6cc): a site that sees either sees the same provider."
	else
		echo "MISMATCH: IPv4 leaves from $v4org ($v4cc), IPv6 from $v6org ($v6cc). A site reached over both can tell them apart. Ask the provider for IPv6 from the same network; nothing here was changed."
	fi
elif [ -n "$v4" ]; then
	echo "IPv6 is unavailable at the upstream, so sites see IPv4 only. That is not a leak. If an IP checker still shows an IPv6 address, it is the device's own, bypassing the tunnel: turn IPv6 off or route it through the tunnel in the client app."
elif [ -n "$v6" ]; then
	echo "Only IPv6 leaves the upstream; sites that have no IPv6 address are unreachable."
else
	echo "No exit answered: the way out through the upstream is broken. \`morzer doctor\` names the layer."
	exit 1
fi
