#!/usr/bin/env bash
# hooks/policy holds the release to its invariants. It passes on the running
# deployment; it names each violation injected into a copy of the rendered
# config, and a container publishing a port nothing should; and `doctor`
# fails on it when the rendered config itself drifts.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

release=/opt/dotdash/current
# A release from before the policy check has nothing to check.
if ! sudo test -x "${release}/hooks/policy" || ! sudo test -f /etc/dotdash/gate.json; then
  echo "${0##*/}: skipped, the installed release predates it (or the gate)"
  exit 0
fi
config=/etc/dotdash/application.yaml
gate=/etc/dotdash/gate.json
policy() { # [config] [gate config]: hooks/policy's output; its status
  sudo env DOTDASH_RELEASE_DIR="${release}" DOTDASH_CONFIG_FILE="${1:-${config}}" \
    DOTDASH_GATE_CONFIG="${2:-${gate}}" DOTDASH_PARAM_HTTPS_PORT=443 DOTDASH_COMPOSE_PROJECT=dotdash \
    "${release}/hooks/policy" 2>&1
}

out=$(policy) || die "policy fails on the running deployment: ${out}"
echo "25-policy.sh: the running deployment keeps every invariant"

work=$(mktemp -d)
caught() { # <jq edit> <phrase the violation must carry> [gate]: edit Xray's config, or the gate's
  local out
  if [ "${3:-}" = gate ]; then
    sudo jq "$1" "${gate}" | tee "${work}/gate.json" >/dev/null
    out=$(policy "${config}" "${work}/gate.json") && die "policy passes a gate config with: $1"
  else
    sudo jq "$1" "${config}" | tee "${work}/config.json" >/dev/null
    out=$(policy "${work}/config.json") && die "policy passes a config with: $1"
  fi
  grep -qF -- "$2" <<<"${out}" || die "policy failed on '$1', but not saying '$2': ${out}"
}
caught '.outbounds += [{tag: "direct", protocol: "freedom"}]' "a freedom outbound"
caught '.outbounds[0].protocol = "freedom"' "a freedom outbound"
# The rig runs resolve=gateway, the default: DoH through the upstream, which
# is handed addresses only. Each edit breaks that one way. A release from
# before the parameter has no DNS of its own to break.
if sudo morzer config list 2>/dev/null | grep -qw resolve; then
  caught '.dns.servers = ["1.1.1.1"]' "DNS other than DoH"
  caught '.dns.servers = ["https+local://1.1.1.1/dns-query"]' "DNS other than DoH"
  caught 'del(.outbounds[0].targetStrategy)' "can still hand it a name"
  caught '.outbounds[0].targetStrategy = "UseIPv4"' "can still hand it a name"
  caught 'del(.dns)' "resolves names with no DNS"
  caught 'del(.dns) | del(.outbounds[0].targetStrategy) | .routing.domainStrategy = "IPIfNonMatch"' "resolves names with no DNS"
fi
caught '.routing.rules += [{network: "tcp", outboundTag: "block"}]' "last routing rule"
caught '(.inbounds[] | select(.tag == "probe")).listen = "0.0.0.0"' "listens beyond loopback"
caught '(.inbounds[] | select(.tag == "reality")).settings.decryption = "none"' "no VLESS decryption"
caught '(.inbounds[] | select(.tag == "xhttp")).settings.flow = "xtls-rprx-vision"' "sets a flow on XHTTP"
caught '.inbounds += [{tag: "debug", listen: "127.0.0.1", port: 9999, protocol: "http"}]' "unexpected inbounds"
caught '.outbounds[0].settings.address = "proxy.example"' "not a SOCKS hop to the gate"
caught '(.inbounds[] | select(.tag == "public-tls")).settings.address = "1.1.1.1"' "forwards public-tls to 1.1.1.1" gate
caught '.routing.rules = [{network: "tcp,udp", outboundTag: "inside"}] + .routing.rules' "out directly" gate
caught '.inbounds += [{tag: "debug", listen: "0.0.0.0", port: 9999, protocol: "http"}]' "unexpected inbounds" gate
caught '.routing.rules |= .[:-1]' "does not block what its rules leave" gate
if sudo grep -q '^  upstream_mode:$' "${release}/manifest.yaml"; then
  caught '.routing.balancers[0].selector = ["inside"]' "not upstreams lines" gate
  caught '.routing.balancers[0].fallbackTag = "inside"' "falls back to inside" gate
  caught '.routing.rules = [{network: "tcp,udp", balancerTag: "egress"}] + .routing.rules' "through a balancer" gate
fi
echo "25-policy.sh: each injected violation is named"

# The image Caddy runs, whichever repository the release pins it from.
caddy=$(sudo docker inspect -f '{{.Config.Image}}' "$(service_container caddy)")
sudo docker run -d --name dotdash-rig-intruder --label com.docker.compose.project=dotdash \
  --label com.docker.compose.service=intruder -p 10809:10809 "${caddy}" caddy respond --listen :10809 x >/dev/null
out=$(policy) && { sudo docker rm -f dotdash-rig-intruder >/dev/null; die "policy passes a container publishing 10809"; }
sudo docker rm -f dotdash-rig-intruder >/dev/null
grep -qF "intruder publishes 10809/tcp" <<<"${out}" || die "policy missed the published 10809: ${out}"
echo "25-policy.sh: a container publishing a port nothing should is named"

xray=$(service_container xray)
sudo docker network connect dotdash_egress "${xray}"
out=$(policy) && { sudo docker network disconnect dotdash_egress "${xray}"; die "policy passes Xray on the egress network"; }
sudo docker network disconnect dotdash_egress "${xray}"
grep -qF "xray is on dotdash_egress, a network with a route out" <<<"${out}" || die "policy missed Xray on the egress network: ${out}"
echo "25-policy.sh: Xray attached to a network with a route out is named"

# Drift: the rendered file changes under the running deployment. Xray reads it
# only at start, so nothing it does changes meanwhile.
sudo cp -p "${config}" "${work}/rendered"
sudo jq '.outbounds += [{tag: "direct", protocol: "freedom"}]' "${work}/rendered" | sudo tee "${config}" >/dev/null
out=$(sudo morzer doctor 2>&1) && status=0 || status=$?
sudo cp -p "${work}/rendered" "${config}"
[ "${status}" -ne 0 ] || die "doctor passes with a freedom outbound in the rendered config"
grep -qF "a freedom outbound" <<<"$(tr '\n' ' ' <<<"${out}" | tr -s ' ')" || die "doctor failed, but not on the policy: ${out}"
sudo morzer doctor >/dev/null 2>&1 || die "doctor still fails after the rendered config was restored"
echo "25-policy.sh: doctor fails when the rendered config drifts, and passes once it is back"
