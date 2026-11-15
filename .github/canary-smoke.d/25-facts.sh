#!/usr/bin/env bash
# The facts task, which an authority reads before every fleet publish: what
# the canary watches, whether each transport gets through, and with
# control_url set, whether the canary's own network answers without dotdash.
# A freeze_url that stops after 20 KB, its connection left open, fails REALITY
# with the bytes it got;
# stopping the stand-in server (pre-apply/10-server.sh) fails it outright.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qF '  facts:' /opt/dotdash-canary/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

facts() {
  local out
  out=$(sudo morzer task run facts --output 2>&1) || die "facts failed: ${out}"
  grep -m1 '^{' <<<"${out}"
}

got=$(facts)
jq -e '.server == "www.gstatic.com" and (.address | length > 0) and (.checked_at | type == "number")
  and .internet == null and .paths == {reality: true} and .stalled == {}' <<<"${got}" >/dev/null ||
  die "facts with the server up: ${got}"

sudo morzer config set control_url=https://www.gstatic.com/generate_204 >/dev/null || die "could not set control_url"
got=$(facts)
jq -e '.internet == true' <<<"${got}" >/dev/null || die "facts with control_url set: ${got}"
echo "25-facts.sh: ${got}"

# A freeze as the canary meets one: bytes stop partway and the connection
# stays open. A stand-in for freeze_url on the rig sends 20 KB of its 64 KB
# answer, then nothing for a minute; the stand-in server reaches it on docker0.
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
dir=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 1 -subj /CN=stall \
  -keyout "${dir}/key.pem" -out "${dir}/cert.pem" 2>/dev/null
python3 - "${dir}" "${host}" <<'PY' &
import http.server, ssl, sys, time


class Stall(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "65536")
        self.end_headers()
        self.wfile.write(b"x" * 20000)
        self.wfile.flush()
        time.sleep(60)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer((sys.argv[2], 9443), Stall)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(f"{sys.argv[1]}/cert.pem", f"{sys.argv[1]}/key.pem")
server.socket = tls.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
stall=$!
sleep 1
sudo morzer config set "freeze_url=https://${host}:9443/f" >/dev/null || die "could not set freeze_url"
got=$(facts) || true
sudo morzer config unset freeze_url >/dev/null || die "could not unset freeze_url"
kill "${stall}" 2>/dev/null || true
jq -e '.internet == true and .paths == {reality: false} and .stalled.reality > 0 and .stalled.reality < 65536' \
  <<<"${got}" >/dev/null || die "facts with freeze_url stopping after 20 KB: ${got}"
echo "25-facts.sh: freeze_url stopped after 20 KB: REALITY reads down after $(jq .stalled.reality <<<"${got}") bytes"
got=$(facts)
jq -e '.paths == {reality: true} and .stalled == {}' <<<"${got}" >/dev/null || die "facts after the freeze: ${got}"

sudo docker stop canary-rig-server >/dev/null
got=$(facts) || true
sudo docker start canary-rig-server >/dev/null
jq -e '.internet == true and .paths == {reality: false}' <<<"${got}" >/dev/null ||
  die "facts with the server stopped: ${got}"
sudo morzer config unset control_url >/dev/null || die "could not unset control_url"
for _ in $(seq 12); do
  if out=$(sudo morzer doctor 2>&1); then
    echo "25-facts.sh: with the server stopped, REALITY does not get through and the network still answers"
    exit 0
  fi
  sleep 5
done
die "doctor still fails after the server came back: ${out}"
