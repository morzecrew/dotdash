#!/bin/sh
# This canary's verdict on the server or relay it watches, as JSON, for an
# authority managing several machines: morzer runs it before every fleet
# publish (manifest `published`, refresh: publish), so the authority reads it
# fresh, not as it was at the last change. dotdash-manager leaves a relay out
# of devices' links once its canaries get through none of its paths a few
# readings in a row.
#
# A path is up when a fetch of probe_url through it succeeds in up to three
# tries, as hooks/healthy checks. internet is whether control_url answers
# without dotdash, so a canary whose own network is down is not read as its
# target blocked; null when control_url is none.
set -eu
: "${DOTDASH_SERVER:?}" "${DOTDASH_ADDRESS:?}" "${PROBE_URL:?}"
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

# busybox wget checks no certificate: this asks only whether anything answers.
case ${CONTROL_URL:-none} in
none) internet=null ;;
*) if wget -q -T 10 -O /dev/null "$CONTROL_URL" 2>/dev/null; then internet=true; else internet=false; fi ;;
esac

paths=
for svc in reality xhttp xhttp-reality mkcp; do
	nc -z -w 2 "$svc" 10809 2>/dev/null || continue
	if up "$svc"; then ok=true; else ok=false; fi
	paths="${paths:+$paths, }\"$svc\": $ok"
done
[ -n "$paths" ] || { echo "no transport answers: is the canary running?" >&2; exit 1; }

printf '{"server": %s, "address": %s, "checked_at": %s, "internet": %s, "paths": {%s}}\n' \
	"$(str "$DOTDASH_SERVER")" "$(str "$DOTDASH_ADDRESS")" "$(date +%s)" "$internet" "$paths"
