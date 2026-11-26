#!/usr/bin/env bash
# cdn=skip: the balancer and its probes take the servers' links
# (dotdash-<n>-*) and the relays' (dotdash-relay-*), never a CDN's
# (dotdash-cdn-*, the servers' and the relays'), and the proxy port still gets
# out through the stand-in's dotdash-1-reality. Unset, every dotdash- link
# again. Xray picks outbounds by tag prefix alone, as picked() does here.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

fetch() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://127.0.0.1:7890 \
    https://www.gstatic.com/generate_204 || true
}
tags='["dotdash-1-reality", "dotdash-12-hy2", "dotdash-relay-1", "dotdash-relay-10-xhttp",
  "dotdash-cdn-1", "dotdash-cdn-relay-1-2"]'
picked() { # <jq path to a selector list>: which of $tags it picks, space-separated
  sudo jq -r --argjson t "${tags}" "$1 as \$s | [\$t[] | select(. as \$g | any(\$s[]; . as \$p | \$g | startswith(\$p)))] | join(\" \")" \
    /etc/dotdash-client/config.json
}

sudo morzer config set cdn=skip >/dev/null
for sel in '.routing.balancers[0].selector' '.burstObservatory.subjectSelector'; do
  [ "$(picked "${sel}")" = "dotdash-1-reality dotdash-12-hy2 dotdash-relay-1 dotdash-relay-10-xhttp" ] ||
    die "cdn=skip: ${sel} picks $(picked "${sel}")"
done
for _ in $(seq 30); do [ "$(fetch)" = 204 ] && break; sleep 2; done
[ "$(fetch)" = 204 ] || die "cdn=skip: the proxy port does not get out through dotdash"

sudo morzer config unset cdn >/dev/null
[ "$(picked '.routing.balancers[0].selector')" = "$(jq -r 'join(" ")' <<<"${tags}")" ] ||
  die "cdn unset: the balancer does not pick every dotdash- link: $(picked '.routing.balancers[0].selector')"
echo "16-cdn.sh: cdn=skip leaves every CDN's link out of the balancer and its probes, and gets out"
