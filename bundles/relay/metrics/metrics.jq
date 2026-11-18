# One Xray's /debug/vars as Prometheus text, for metrics.sh: its traffic per
# inbound and outbound and its observatory's verdicts, every series labelled
# with $product and $role. Never per device: the "user" counters are left out
# (the configs keep none anyway).
def esc: tostring | gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | gsub("\n"; "\\n");
def labels($more): "{product=\"\($product | esc)\",role=\"\($role | esc)\""
  + ($more | to_entries | map(",\(.key)=\"\(.value | esc)\"") | join("")) + "}";
def block($name; $type; $help; $lines):
  if ($lines | length) > 0 then "# HELP \($name) \($help)", "# TYPE \($name) \($type)", $lines[] else empty end;
def bytes($kind):
  [(.stats[$kind] // {}) | to_entries[] | .key as $tag | .value | to_entries[]
   | select((.key == "uplink" or .key == "downlink") and (.value | type) == "number")
   | "dotdash_\($kind)_bytes_total\(labels({($kind): $tag, direction: .key})) \(.value)"];
(.observatory // {} | if type == "object" then to_entries else [] end) as $obs
| block("dotdash_xray_up"; "gauge"; "1 when the Xray's metrics endpoint answered"; ["dotdash_xray_up\(labels({})) 1"]),
  block("dotdash_inbound_bytes_total"; "counter"; "bytes through an inbound since the Xray started, by direction"; bytes("inbound")),
  block("dotdash_outbound_bytes_total"; "counter"; "bytes through an outbound since the Xray started, by direction"; bytes("outbound")),
  block("dotdash_observatory_alive"; "gauge"; "1 when the Xray's observatory last found the outbound alive";
    [$obs[] | select(.value | type == "object") | "dotdash_observatory_alive\(labels({outbound: .key})) \(if .value.alive then 1 else 0 end)"]),
  block("dotdash_observatory_delay_seconds"; "gauge"; "the observatory's last delay through an alive outbound";
    [$obs[] | select((.value | type == "object") and .value.alive and (.value.delay | type) == "number")
     | "dotdash_observatory_delay_seconds\(labels({outbound: .key})) \(.value.delay / 1000)"]),
  block("dotdash_xray_heap_bytes"; "gauge"; "the Go heap the Xray holds, beside its GOMEMLIMIT";
    [.memstats.HeapAlloc | select(type == "number") | "dotdash_xray_heap_bytes\(labels({})) \(.)"])
