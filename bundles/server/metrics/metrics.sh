#!/bin/sh
# metrics.sh <product> <role> <url>: the metrics profile's exporter. Every
# minute, the Xray's metrics endpoint (/debug/vars, on the metrics network)
# turned into Prometheus text by metrics.jq, written to the node exporter's
# textfile directory (/textfile) as dotdash-<product>-<role>.prom, to a
# temporary name renamed into place, as morzer writes its own. With no
# answer, dotdash_xray_up is 0. A relay's gateway status, mounted at
# /gateway, adds each server group's state. jq is the jq image's, mounted at
# /jq.
#
# metrics.sh --demo checks the conversion against a sample, with the jq on PATH.
set -u
here=$(dirname "$0")
jq=/jq/jq
[ -x "$jq" ] || jq=jq

gw=/gateway/status.json
convert() { # <product> <role>: /debug/vars on stdin, the textfile on stdout
  g=$gw
  [ -r "$g" ] || g=/dev/null
  "$jq" -r --arg product "$1" --arg role "$2" --slurpfile gw "$g" -f "$here/metrics.jq"
}

if [ "${1:-}" = --demo ]; then
  gw=$(mktemp)
  trap 'rm -f "$gw"' EXIT
  printf '%s' '{"groups": [{"name": "a", "state": "live", "devices": 14, "listed": "2020-01-01T00:00:00.5Z"},
    {"name": "b", "state": "down", "devices": 3}]}' >"$gw"
  out=$(printf '%s' '{"stats": {"inbound": {"reality": {"uplink": 10, "downlink": 2000}},
    "outbound": {"gate": {"uplink": 12, "downlink": 2100}}, "user": {"x": {"uplink": 5}}},
    "observatory": {"upstream-a": {"alive": true, "delay": 120}, "upstream-b": {"alive": false, "delay": 99}},
    "memstats": {"HeapAlloc": 8388608}}' | convert dotdash xray) || { echo "metrics.sh: jq failed" >&2; exit 1; }
  for want in 'dotdash_xray_up{product="dotdash",role="xray"} 1' \
    'dotdash_inbound_bytes_total{product="dotdash",role="xray",inbound="reality",direction="downlink"} 2000' \
    'dotdash_outbound_bytes_total{product="dotdash",role="xray",outbound="gate",direction="uplink"} 12' \
    'dotdash_observatory_alive{product="dotdash",role="xray",outbound="upstream-b"} 0' \
    'dotdash_observatory_delay_seconds{product="dotdash",role="xray",outbound="upstream-a"} 0.12' \
    'dotdash_xray_heap_bytes{product="dotdash",role="xray"} 8388608' \
    'dotdash_group_live{product="dotdash",role="xray",group="a"} 1' \
    'dotdash_group_live{product="dotdash",role="xray",group="b"} 0' \
    'dotdash_group_devices{product="dotdash",role="xray",group="b"} 3' \
    '# TYPE dotdash_inbound_bytes_total counter'; do
    printf '%s\n' "$out" | grep -qxF "$want" || { echo "metrics.sh: no line: $want" >&2; exit 1; }
  done
  if printf '%s\n' "$out" | grep -q 'outbound="upstream-b"} 0\.\|"x"'; then
    echo "metrics.sh: a dead outbound's delay, or a user" >&2
    exit 1
  fi
  printf '%s\n' "$out" | grep -qE '^dotdash_group_list_age_seconds\{product="dotdash",role="xray",group="a"\} [0-9]{8,}$' ||
    { echo "metrics.sh: no list age for group a" >&2; exit 1; }
  echo "metrics.sh: ok"
  exit 0
fi

product=${1:?product} role=${2:?role} url=${3:?url}
out=/textfile/dotdash-$product-$role.prom
while :; do
  wget -q -T 10 -O /tmp/vars "$url" 2>/dev/null && convert "$product" "$role" </tmp/vars >"$out.tmp" ||
    printf '# HELP dotdash_xray_up 1 when the metrics endpoint answered\n# TYPE dotdash_xray_up gauge\ndotdash_xray_up{product="%s",role="%s"} 0\n' \
      "$product" "$role" >"$out.tmp"
  chmod 0644 "$out.tmp" && mv "$out.tmp" "$out"
  sleep 60
done
