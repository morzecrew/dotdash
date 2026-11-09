#!/usr/bin/env bash
# Several dotdash servers: the relay renders one outbound per server, each
# reached and named by its own domain (dotdash_address applies to a single
# server only), behind a leastPing balancer that every connection takes. The
# rig's one stand-in can't stand behind three names, so this checks the
# rendered config, then goes back to the stand-in and gets through again.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

sudo morzer config set dotdash_servers=a.invalid,b.invalid,c.invalid >/dev/null
sudo jq -e '
  [.outbounds[] | {tag, address: .settings.address, name: .streamSettings.realitySettings.serverName}]
    == [{tag: "dotdash-0", address: "a.invalid", name: "a.invalid"},
        {tag: "dotdash-1", address: "b.invalid", name: "b.invalid"},
        {tag: "dotdash-2", address: "c.invalid", name: "c.invalid"}]
  and .routing.balancers == [{tag: "dotdash", selector: ["dotdash-"], strategy: {type: "leastPing"}}]
  and .routing.rules == [{type: "field", network: "tcp,udp", balancerTag: "dotdash"}]
  and .observatory.subjectSelector == ["dotdash-"]' /etc/dotdash-relay/xray.json >/dev/null \
  || die "three servers did not render three outbounds behind a balancer: $(sudo jq -c '{outbounds: [.outbounds[].settings.address], routing}' /etc/dotdash-relay/xray.json)"

sudo morzer config set dotdash_servers=www.gstatic.com >/dev/null
sudo jq -e '(.outbounds | length) == 1 and (.routing == null)' /etc/dotdash-relay/xray.json >/dev/null \
  || die "one server renders a balancer or more than one outbound"
for _ in $(seq 15); do
  sudo morzer doctor >/dev/null 2>&1 && break
  sleep 2
done
out=$(sudo morzer doctor 2>&1) || die "back on the stand-in, the relay does not get out: ${out}"
echo "15-servers.sh: several servers render an outbound each behind a balancer; one renders one"
