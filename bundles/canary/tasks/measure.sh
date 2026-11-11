#!/bin/sh
# Measures each transport this canary runs, REALITY and, under their profiles,
# XHTTP, XHTTP with REALITY or mKCP: N fetches of a URL through each, as JSON, with how many succeeded,
# timed out or failed otherwise, and the latency of the ones that succeeded;
# then three downloads of download_url through each, with how many completed
# and the median Mbit/s. What it measures is the way through dotdash from this
# network, not the exit the upstream gives it; dotdash's exit-check covers
# that.
#
#   measure.sh [count] [url] [timeout]
#
# Each fetch is the image's own healthcheck through the service's probe
# inbound, so an https URL works. Latency comes from /proc/uptime, to 10ms.
set -eu
count=${1:-20}
url=${2:-${PROBE_URL:-https://www.gstatic.com/generate_204}}
timeout=${3:-10s}
download_url=${DOWNLOAD_URL:-https://speed.cloudflare.com/__down?bytes=1000000}
[ "$download_url" != none ] || download_url=
# wget goes through the probe inbound by https_proxy alone (with http_proxy
# too, busybox sends an https URL to the proxy as a plain GET, which Xray
# refuses), so a plain http URL would leave around dotdash: refused.
case $download_url in '' | https://*) ;; *) echo "download_url must be https://, not '$download_url'" >&2; exit 2 ;; esac
downloads=3
case $count in '' | *[!0-9]*) echo "count must be a number, not '$count'" >&2; exit 2 ;; esac

# %.0f, not %d: busybox awk's %d is 32 bits, which uptime in milliseconds
# outgrows after 25 days.
now_ms() { awk '{ printf "%.0f\n", $1 * 1000 }' /proc/uptime; }

download() { # <service>: the downloads through it, as a JSON object
	got=0 rates=''
	j=0
	while [ "$j" -lt "$downloads" ]; do
		j=$((j + 1))
		start=$(now_ms)
		# busybox wget, through the probe inbound, an HTTP proxy. It checks no
		# certificate, which a speed test that runs inside the tunnel and
		# carries nothing secret can do without. pipefail, so a transfer cut
		# short is not counted as done.
		# shellcheck disable=SC3040 # busybox ash has pipefail
		if n=$(set -o pipefail; https_proxy="http://$1:10809" \
			wget -q -T 60 -O - "$download_url" 2>/dev/null | wc -c); then
			n=$(echo "$n" | tr -d ' ')
			ms=$(($(now_ms) - start))
			if [ "$n" -gt 0 ] && [ "$ms" -gt 0 ]; then
				got=$((got + 1))
				rates="$rates $(awk -v b="$n" -v ms="$ms" 'BEGIN { printf "%.2f", b * 8 / ms / 1000 }')"
			fi
		fi
	done
	# shellcheck disable=SC2086 # one rate per word
	printf '%s\n' $rates | sort -n | awk -v n="$downloads" -v ok="$got" '
		NF { r[++k] = $1 }
		END {
			printf "{\"of\": %d, \"ok\": %d, \"mbps_p50\": ", n, ok
			if (k) printf "%s}", r[int((k + 1) / 2)]; else printf "null}"
		}'
}

measure() { # <service>: one JSON object
	ok=0 timeouts=0 errors=0 times='' last=''
	i=0
	while [ "$i" -lt "$count" ]; do
		i=$((i + 1))
		start=$(now_ms)
		if out=$(XRAY_HEALTHCHECK_PROXY="http://$1:10809" XRAY_HEALTHCHECK_URL="$url" \
			XRAY_HEALTHCHECK_TIMEOUT="$timeout" /opt/xray/xray-entrypoint healthcheck 2>&1); then
			ok=$((ok + 1))
			times="$times $(($(now_ms) - start))"
		else
			case $out in
			*Timeout* | *timeout* | *"deadline exceeded"*) timeouts=$((timeouts + 1)) ;;
			*) errors=$((errors + 1)) ;;
			esac
			last=$(printf '%s' "$out" | tail -n1 | cut -c1-200)
		fi
	done
	if [ -n "$download_url" ]; then dl=$(download "$1"); else dl=; fi
	# shellcheck disable=SC2086 # one latency per word
	# The error goes through the environment: awk -v would read its backslashes.
	printf '%s\n' $times | sort -n | LAST=$last DL=$dl awk -v svc="$1" -v n="$count" -v ok="$ok" \
		-v to="$timeouts" -v err="$errors" '
		NF { t[++k] = $1 }
		function pct(p,   i) { i = int((k * p + 99) / 100); if (i < 1) i = 1; return t[i] }
		END {
			printf "    \"%s\": {\"requests\": %d, \"ok\": %d, \"timeouts\": %d, \"errors\": %d, ", svc, n, ok, to, err
			printf "\"success_rate\": %.3f, \"latency_ms\": ", ok / n
			if (k) printf "{\"p50\": %d, \"p95\": %d, \"max\": %d}", pct(50), pct(95), t[k]
			else printf "null"
			last = ENVIRON["LAST"]
			gsub(/\\/, "\\\\", last); gsub(/"/, "\\\"", last); gsub(/\t/, " ", last)
			if (last != "") printf ", \"last_error\": \"%s\"", last
			if (ENVIRON["DL"] != "") printf ", \"download\": %s", ENVIRON["DL"]
			printf "}"
		}'
}

services=
for svc in reality xhttp xhttp-reality mkcp; do
	nc -z -w 2 "$svc" 10809 2>/dev/null && services="$services $svc"
done
[ -n "$services" ] || { echo "no transport answers: is the canary running?" >&2; exit 1; }

json() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf '{\n  "url": "%s",\n  "timeout": "%s",\n  "download_url": "%s",\n  "transports": {\n' \
	"$(json "$url")" "$(json "$timeout")" "$(json "${download_url:-none}")"
first=1
for svc in $services; do
	[ "$first" = 1 ] || printf ',\n'
	first=0
	measure "$svc"
done
printf '\n  }\n}\n'
