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
# with no byte for 8 seconds or cut, twice running, makes the path down, and
# stalled gives the bytes it got. One that gets no byte at all says nothing
# of a freeze (freeze_url's own host may be down) and leaves the path up.
#
# internet is whether control_url answers without dotdash, so a canary whose
# own network is down is not read as its target blocked; null when
# control_url is none.
set -eu
: "${DOTDASH_SERVER:?}" "${DOTDASH_ADDRESS:?}" "${PROBE_URL:?}"
freeze_url=${FREEZE_URL:-none}
[ "$freeze_url" != none ] || freeze_url=
# wget reaches the probe inbound by https_proxy alone, as measure's downloads.
case $freeze_url in '' | https://*) ;; *) echo "freeze_url must be https://, not '$freeze_url'" >&2; exit 2 ;; esac
str() {
	case $1 in *[[:cntrl:]]*) echo "facts: a value holds a control character" >&2; exit 1 ;; esac
	printf '"%s"' "$(printf '%s' "$1" | sed 's/[\\"]/\\&/g')"
}
up() { # <service>
	for try in 1 2 3; do
		XRAY_HEALTHCHECK_PROXY="http://$1:10809" XRAY_HEALTHCHECK_URL="$PROBE_URL" XRAY_HEALTHCHECK_TIMEOUT=7s \
			/opt/xray/xray-entrypoint healthcheck >/dev/null 2>&1 && return 0
		[ "$try" = 3 ] || sleep 2
	done
	return 1
}
frozen() { # <service>: prints the bytes and succeeds when freeze_url stops partway twice
	for try in 1 2; do
		# busybox wget's -T is a read timeout: no byte for 8 seconds ends it.
		# shellcheck disable=SC3040 # busybox ash has pipefail
		if n=$(set -o pipefail; https_proxy="http://$1:10809" \
			wget -q -T 8 -O - "$freeze_url" 2>/dev/null | wc -c); then
			return 1
		fi
		n=$(echo "$n" | tr -d ' ')
		[ "$n" -gt 0 ] || return 1
		[ "$try" = 2 ] || sleep 1
	done
	echo "$n"
}

# busybox wget checks no certificate: this asks only whether anything answers.
case ${CONTROL_URL:-none} in
none) internet=null ;;
*) if wget -q -T 10 -O /dev/null "$CONTROL_URL" 2>/dev/null; then internet=true; else internet=false; fi ;;
esac

paths='' stalled=''
for svc in reality xhttp xhttp-reality mkcp; do
	nc -z -w 2 "$svc" 10809 2>/dev/null || continue
	if ! up "$svc"; then
		ok=false
	elif [ -n "$freeze_url" ] && got=$(frozen "$svc"); then
		ok=false
		stalled="${stalled:+$stalled, }\"$svc\": $got"
	else
		ok=true
	fi
	paths="${paths:+$paths, }\"$svc\": $ok"
done
[ -n "$paths" ] || { echo "no transport answers: is the canary running?" >&2; exit 1; }

printf '{"server": %s, "address": %s, "checked_at": %s, "internet": %s, "paths": {%s}, "stalled": {%s}}\n' \
	"$(str "$DOTDASH_SERVER")" "$(str "$DOTDASH_ADDRESS")" "$(date +%s)" "$internet" "$paths" "$stalled"
