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
if ! sudo test -x "${release}/hooks/policy"; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi
config=/etc/dotdash/application.yaml
policy() { # [config]: hooks/policy's output; its status
  sudo env DOTDASH_RELEASE_DIR="${release}" DOTDASH_CONFIG_FILE="${1:-${config}}" \
    DOTDASH_PARAM_HTTPS_PORT=443 DOTDASH_COMPOSE_PROJECT=dotdash "${release}/hooks/policy" 2>&1
}

out=$(policy) || die "policy fails on the running deployment: ${out}"
echo "25-policy.sh: the running deployment keeps every invariant"

work=$(mktemp -d)
caught() { # <jq edit> <phrase the violation must carry>
  sudo jq "$1" "${config}" | tee "${work}/config.json" >/dev/null
  local out
  if out=$(policy "${work}/config.json"); then
    die "policy passes a config with: $1"
  fi
  grep -qF -- "$2" <<<"${out}" || die "policy failed on '$1', but not saying '$2': ${out}"
}
caught '.outbounds += [{tag: "direct", protocol: "freedom"}]' "a freedom outbound"
caught '.outbounds[0].protocol = "freedom"' "a freedom outbound"
caught '.routing.domainStrategy = "IPIfNonMatch"' "resolves names itself"
caught '.dns = {servers: ["1.1.1.1"]}' "DNS section of its own"
caught '.routing.rules += [{network: "tcp", outboundTag: "block"}]' "last routing rule"
caught '(.inbounds[] | select(.tag == "probe")).listen = "0.0.0.0"' "listens beyond loopback"
caught '(.inbounds[] | select(.tag == "reality")).settings.decryption = "none"' "no VLESS decryption"
caught '(.inbounds[] | select(.tag == "xhttp")).settings.flow = "xtls-rprx-vision"' "sets a flow on XHTTP"
caught '.inbounds += [{tag: "debug", listen: "127.0.0.1", port: 9999, protocol: "http"}]' "unexpected inbounds"
echo "25-policy.sh: each injected violation is named"

caddy=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' caddy | sed -n 1p)
sudo docker run -d --name dotdash-rig-intruder --label com.docker.compose.project=dotdash \
  --label com.docker.compose.service=intruder -p 10809:10809 "${caddy}" caddy respond --listen :10809 x >/dev/null
out=$(policy) && { sudo docker rm -f dotdash-rig-intruder >/dev/null; die "policy passes a container publishing 10809"; }
sudo docker rm -f dotdash-rig-intruder >/dev/null
grep -qF "intruder publishes 10809/tcp" <<<"${out}" || die "policy missed the published 10809: ${out}"
echo "25-policy.sh: a container publishing a port nothing should is named"

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
