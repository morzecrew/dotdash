#!/bin/sh
# This canary's verdict on the server or relay it watches, as JSON, for an
# authority managing several machines: morzer runs it before every fleet
# publish (manifest `published`, refresh: publish), so the authority reads it
# fresh, not as it was at the last change. dotdash-manager leaves a relay out
# of devices' links once its canaries get through none of its paths a few
# readings in a row.
#
# A path is up when a fetch of probe_url through it succeeds in up to three
# tries, as hooks/healthy checks, and then a download of freeze_url through
# it does not stop partway. A network's DPI may freeze a connection to a
# hosting address abroad after its first 16-20 KB, leaving it open and silent;
# probe_url's fetch is too small to reach that, so a frozen path would still
# read as up. freeze_url is past it (64 KB). A download that stops partway,
# with no byte for 8 seconds, cut, or not done in 40, twice running, makes
# the path down, and stalled gives the bytes it got. One that gets no byte at
# all says nothing of a freeze (freeze_url's own host may be down) and leaves
# the path up. freeze_up_url is the same the other way, for a network that
# counts what a device sends: a 64 KB upload that gets no answer for 8
# seconds, twice running, makes the path down, named in stalled_up. One that
# fails sooner (refused, an error page) says nothing of a freeze. Both go
# through the path's probe inbound by the Xray image's fetch, which checks an
# https URL's certificate.
#
# internet is whether control_url answers without dotdash, so a canary whose
# own network is down is not read as its target blocked; null when
# control_url is none.
#
# latency_ms gives each path that is up the time its probe_url fetch took, a
# new connection's worth: this network's leg, the target's, and on to the
# site. direct_ms is control_url's fetch without dotdash, this network's leg
# alone, null when it didn't answer or is none. To 10 ms (/proc/uptime).
set -eu
: "${DOTDASH_SERVER:?}" "${DOTDASH_ADDRESS:?}" "${PROBE_URL:?}"
freeze_url=${FREEZE_URL:-none}
[ "$freeze_url" != none ] || freeze_url=
case $freeze_url in '' | http://* | https://*) ;; *) echo "freeze_url must be http:// or https://, not '$freeze_url'" >&2; exit 2 ;; esac
freeze_up_url=${FREEZE_UP_URL:-none}
[ "$freeze_up_url" != none ] || freeze_up_url=
case $freeze_up_url in '' | http://* | https://*) ;; *) echo "freeze_up_url must be http:// or https://, not '$freeze_up_url'" >&2; exit 2 ;; esac
str() {
	case $1 in *[[:cntrl:]]*) echo "facts: a value holds a control character" >&2; exit 1 ;; esac
	printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}
# %.0f, not %d: busybox awk's %d is 32 bits, which uptime in milliseconds
# outgrows after 25 days.
now_ms() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }
up() { # <service> [port] [url]: prints the milliseconds of the fetch that succeeded
	for try in 1 2 3; do
		start=$(now_ms)
		if XRAY_HEALTHCHECK_PROXY="http://$1:${2:-10809}" XRAY_HEALTHCHECK_URL="${3:-$PROBE_URL}" XRAY_HEALTHCHECK_TIMEOUT=7s \
			/opt/xray/xray-entrypoint healthcheck >/dev/null 2>&1; then
			echo $(($(now_ms) - start))
			return 0
		fi
		[ "$try" = 3 ] || sleep 2
	done
	return 1
}
# fetch prints "<bytes> <ms>" and exits 0 for a whole body, 1 for no byte of
# one, 3 for some bytes, then cut, nothing for -read-timeout, or -timeout.
frozen() { # <service>: prints the bytes and succeeds when freeze_url stops partway twice
	for try in 1 2; do
		rc=0
		got=$(/opt/xray/xray-entrypoint fetch -proxy "http://$1:10809" -read-timeout 8s -timeout 40s "$freeze_url" 2>/dev/null) || rc=$?
		[ "$rc" = 3 ] || return 1
		[ "$try" = 2 ] || sleep 1
	done
	echo "${got% *}"
}
udp_ok() { # <service>: a DNS question sent over UDP through it (its udp inbound, to udp_target) gets an answer
	for try in 1 2; do
		# example.com, type A, with recursion: 29 bytes, in octal for busybox's printf.
		n=$(printf '\022\064\001\000\000\001\000\000\000\000\000\000\007example\003com\000\000\001\000\001' |
			nc -u -w 5 "$1" 10811 2>/dev/null | wc -c)
		[ "$(echo "$n" | tr -d ' ')" -le 12 ] || return 0
		[ "$try" = 2 ] || sleep 1
	done
	return 1
}
frozen_up() { # <service>: succeeds when a 64 KB upload to freeze_up_url gets no answer for 8 seconds, twice
	for try in 1 2; do
		# -read-timeout times a write that blocks as well as the wait for the answer.
		out=$(/opt/xray/xray-entrypoint fetch -proxy "http://$1:10809" -upload 65536 -read-timeout 8s -timeout 40s \
			"$freeze_up_url" 2>/dev/null) && return 1
		[ "${out#* }" -ge 8000 ] || return 1
		[ "$try" = 2 ] || sleep 1
	done
}

# busybox wget checks no certificate: this asks only whether anything answers.
direct=null
case ${CONTROL_URL:-none} in
none) internet=null ;;
*)
	start=$(now_ms)
	if wget -q -T 10 -O /dev/null "$CONTROL_URL" 2>/dev/null; then
		internet=true direct=$(($(now_ms) - start))
	else
		internet=false
	fi
	;;
esac

paths='' stalled='' stalled_up='' latency='' udp='' ipv6=''
for svc in reality xhttp xhttp-reality mkcp hysteria2; do
	nc -z -w 2 "$svc" 10809 2>/dev/null || continue
	if ! ms=$(up "$svc"); then
		ok=false
	elif [ -n "$freeze_url" ] && got=$(frozen "$svc"); then
		ok=false
		stalled="${stalled:+$stalled, }\"$svc\": $got"
	elif [ -n "$freeze_up_url" ] && frozen_up "$svc"; then
		ok=false
		stalled_up="${stalled_up:+$stalled_up, }\"$svc\""
	else
		ok=true
		latency="${latency:+$latency, }\"$svc\": $ms"
	fi
	paths="${paths:+$paths, }\"$svc\": $ok"
	# Whether the server carries UDP through this transport (upstream_udp).
	if udp_ok "$svc"; then u=true; else u=false; fi
	udp="${udp:+$udp, }\"$svc\": $u"
	# Whether the server carries IPv6 through this transport (ipv6_url).
	if [ "${IPV6_URL:-none}" != none ]; then
		if up "$svc" 10809 "$IPV6_URL" >/dev/null; then v=true; else v=false; fi
		ipv6="${ipv6:+$ipv6, }\"$svc\": $v"
	fi
done
[ -n "$paths" ] || { echo "no transport answers: is the canary running?" >&2; exit 1; }
# REALITY with its ClientHello split into TLS records (templates/reality.json.tmpl):
# getting through when REALITY itself doesn't is a block on the server's name.
reality_split=null
if nc -z -w 2 reality 10810 2>/dev/null; then
	if up reality 10810 >/dev/null; then reality_split=true; else reality_split=false; fi
fi
# A burst through REALITY: six connections at once, as a page's parallel
# requests make with Vision, which opens one outer connection to the server
# for each, then one more. A network that freezes a device opening more than
# a few connections to one address within a fraction of a second freezes it
# for minutes (dotdash-lab #65), which a check of one connection at a time
# never sets off: REALITY then passes alone and stalls pages. Last of the
# checks, since it freezes every one after it, and only while REALITY gets
# through, which it then no longer does.
burst=null
case "${BURST_CHECK:-true}:$paths" in
true:*'"reality": true'*)
	for _ in 1 2 3 4 5 6; do
		XRAY_HEALTHCHECK_PROXY=http://reality:10809 XRAY_HEALTHCHECK_URL="$PROBE_URL" XRAY_HEALTHCHECK_TIMEOUT=7s \
			/opt/xray/xray-entrypoint healthcheck >/dev/null 2>&1 &
	done
	wait
	sleep 2
	if up reality >/dev/null; then
		burst=false
	else
		burst=true
		paths=$(printf '%s' "$paths" | sed 's/"reality": true/"reality": false/')
		# Its time, first in the list as REALITY is in the loop, goes too.
		latency=$(printf '%s' "$latency" | sed 's/^"reality": [0-9]*\(, \)\{0,1\}//')
	fi
	;;
esac
# With REALITY failing, what stops it, from this network: its connections
# frozen partway (freeze_url, freeze_up_url: freeze); no TCP connection to the
# server's port at all, a block on its address (ip); a connection, with the
# split hello getting through, a block on its name by SNI (sni); a connection,
# with the split failing too, a block on the TLS or on REALITY itself (tls);
# alone through, frozen by a burst (burst). Null while REALITY gets through.
blocked_by=null
case $paths in *'"reality": false'*)
	case "$burst $stalled $stalled_up" in
	true*) blocked_by='"burst"' ;;
	*'"reality"'*) blocked_by='"freeze"' ;;
	*)
		if ! nc -z -w 5 "$DOTDASH_ADDRESS" "${DOTDASH_PORT:-443}" 2>/dev/null; then blocked_by='"ip"'
		elif [ "$reality_split" = true ]; then blocked_by='"sni"'
		else blocked_by='"tls"'; fi ;;
	esac ;;
esac

printf '{"server": %s, "address": %s, "public_key": %s, "checked_at": %s, "internet": %s, "paths": {%s}, "reality_split": %s, "burst": %s, "blocked_by": %s, "udp": {%s}, "ipv6": {%s}, "stalled": {%s}, "stalled_up": [%s], "latency_ms": {%s}, "direct_ms": %s}\n' \
	"$(str "$DOTDASH_SERVER")" "$(str "$DOTDASH_ADDRESS")" "$(str "${DOTDASH_PUBLIC_KEY:-}")" "$(date +%s)" "$internet" "$paths" "$reality_split" "$burst" "$blocked_by" "$udp" "$ipv6" "$stalled" "$stalled_up" \
	"$latency" "$direct"
