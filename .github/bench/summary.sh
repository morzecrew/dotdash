#!/usr/bin/env bash
# Markdown for a benchmark's JSON (bench.sh), one row per scenario and
# transport; with a baseline, each figure carries its change from it.
#
#   summary.sh <bench.json> [baseline.json]
set -euo pipefail

jq -r --slurpfile base "${2:-/dev/null}" '
  ($base[0].scenarios // []) as $b
  | def key: "\(.delay_ms)/\(.jitter_ms)/\(.loss_pct)/\(.transport)";
    def was($s): $b | map(select(key == ($s | key))) | first;
    def pct: if . == null then "–" else "\(. * 100 | floor)%" end;
    def ms: if . == null then "–" else "\(.) ms" end;
    def delta($now; $then; $unit; $scale):
      if $now == null or $then == null then ""
      else (($now - $then) * $scale | round) as $d
        | if $d == 0 then "" elif $d > 0 then " (+\($d)\($unit))" else " (\($d)\($unit))" end end;
  "### dotdash benchmark",
  "",
  "\(.xray), release \(.release // "?"), kernel \(.kernel); \(.requests) fetches and \(.transfers) × 1 MiB per row; netem \(.netem).",
  "",
  "| delay | loss | transport | fetches ok | TTFB p50 | TTFB p95 | 1 MiB done | Mbit/s p50 |",
  "| --- | --- | --- | --- | --- | --- | --- | --- |",
  (.scenarios[] as $s | was($s) as $w |
    "| \($s.delay_ms) ms ± \($s.jitter_ms) | \($s.loss_pct)% | \($s.transport) "
    + "| \($s.requests.success_rate | pct)\(delta($s.requests.success_rate; $w.requests.success_rate; " pt"; 100)) "
    + "| \($s.requests.ttfb_ms.p50 | ms)\(delta($s.requests.ttfb_ms.p50; $w.requests.ttfb_ms.p50; " ms"; 1)) "
    + "| \($s.requests.ttfb_ms.p95 | ms)\(delta($s.requests.ttfb_ms.p95; $w.requests.ttfb_ms.p95; " ms"; 1)) "
    + "| \($s.transfers.ok)/\($s.transfers.of) "
    + "| \($s.transfers.mbps_p50 // "–")\(delta($s.transfers.mbps_p50; $w.transfers.mbps_p50; ""; 1)) |"),
  "",
  "Back through after `morzer restart xray`: REALITY \(.reconnect_after_restart_s.reality) s, XHTTP \(.reconnect_after_restart_s.xhttp) s."
  + (if ($base | length) > 0 then " Changes in brackets are against the last benchmark of `main`." else "" end)
' "$1"
