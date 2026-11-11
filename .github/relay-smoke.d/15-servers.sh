#!/usr/bin/env bash
# Several dotdash servers: the relay renders one outbound per server, each
# reached and named by its own domain (dotdash_address applies to a single
# server only), behind a leastPing balancer that every connection takes. The
# rig's one stand-in can't stand behind three names, and morzer (0.16) undoes
# a config set whose health check fails, so three servers are checked in the
# plan, whose diff renders the config without applying it; then one server,
# the stand-in, is checked on disk and gets through.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

plan=$(sudo morzer config set dotdash_servers=a.invalid,b.invalid,c.invalid --dry-run 2>&1) \
  || die "could not plan three servers: ${plan}"
for want in '"tag": "dotdash-2", "protocol": "vless"' '"address": "a.invalid", "port": 443' \
  '"serverName": "c.invalid", "fingerprint": "chrome"' \
  '"balancers": [{"tag": "dotdash", "selector": ["dotdash-"], "strategy": {"type": "leastPing"}}]' \
  '"rules": [{"type": "field", "network": "tcp,udp", "balancerTag": "dotdash"}' \
  '"observatory": {"subjectSelector": ["dotdash-"]'; do
  grep -qF -- "${want}" <<<"${plan}" || die "the plan for three servers renders no ${want}: $(tail -n 40 <<<"${plan}")"
done

sudo morzer config set dotdash_servers=www.gstatic.com >/dev/null
sudo jq -e '(.outbounds | length) == 1 and (.routing == null)' /etc/dotdash-relay/xray.json >/dev/null \
  || die "one server renders a balancer or more than one outbound"
for _ in $(seq 15); do
  sudo morzer doctor >/dev/null 2>&1 && break
  sleep 2
done
out=$(sudo morzer doctor 2>&1) || die "back on the stand-in, the relay does not get out: ${out}"
echo "15-servers.sh: several servers render an outbound each behind a balancer; one renders one"
