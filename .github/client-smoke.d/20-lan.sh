#!/usr/bin/env bash
# Published beyond 127.0.0.1, the proxy port asks for proxy_user and
# proxy_password: without them it refuses (407 over HTTP, and SOCKS5 refuses),
# with them it gets out. Back on 127.0.0.1, it asks for nothing again.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
fetch() { # <proxy URL>: the status of a plain-HTTP 204 through it, or 000; plain
  # HTTP, so a proxy's 407 is the status itself rather than a failed CONNECT
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy "$1" http://www.gstatic.com/generate_204 || true
}
poll() { # <want> <proxy URL> <what>
  local code
  for _ in $(seq 30); do code=$(fetch "$2"); [ "${code}" = "$1" ] && return 0; sleep 2; done
  die "$3 (last status ${code})"
}

sudo morzer config set listen=0.0.0.0 >/dev/null
password=$(sudo cat /run/dotdash-client/secrets/proxy_password)
poll 407 "http://${host}:7890" "published on the network, the port does not ask for a password"
code=$(fetch "socks5h://${host}:7890")
[ "${code}" != 204 ] || die "published on the network, SOCKS5 gets out with no password"
poll 204 "http://dotdash:${password}@${host}:7890" "with proxy_user and proxy_password the port does not get out"
code=$(fetch "socks5h://dotdash:${password}@${host}:7890")
[ "${code}" = 204 ] || die "SOCKS5 with proxy_user and proxy_password got ${code}"

sudo morzer config set listen=127.0.0.1 >/dev/null
poll 204 http://127.0.0.1:7890 "back on 127.0.0.1, the port asks for a password"
code=$(fetch "http://${host}:7890")
[ "${code}" = 000 ] || die "back on 127.0.0.1, the port still answers on the network (${code})"
echo "20-lan.sh: on the network only with proxy_user and proxy_password; on 127.0.0.1 with none"
