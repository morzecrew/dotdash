#!/usr/bin/env bash
# What a server's Caddy relies on: the register task gives a registration and
# its CNAME, the API takes a DNS-01 token under it, and the zone answers that
# token over the published port 53, as a CA's resolver would ask it.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

out=$(sudo morzer task run register --output -- s.rig.invalid. 2>&1) || die "register failed: $(tail -3 <<<"${out}")"
grep -qE '^_acme-challenge\.s\.rig\.invalid\.  CNAME  [0-9a-f-]+\.auth\.rig\.invalid\.$' <<<"${out}" ||
  die "register printed no CNAME for s.rig.invalid"
secret=$(grep -m1 '^{' <<<"${out}") || die "register printed no secret"
jq -e '(.username | length > 0) and (.password | length > 0) and (.subdomain | length > 0)
  and .server_url == "http://auth.rig.invalid:443"' <<<"${secret}" >/dev/null ||
  die "the secret register printed is not a registration: keys $(jq -c keys <<<"${secret}" 2>/dev/null)"

# Caddy's update, from inside the project's network, then the TXT over the
# rig's published port. A token is 43 characters.
token=$(random | cut -c1-43)
container=$(service_container acme-dns)
image=$(sudo docker inspect --format '{{.Config.Image}}' "${container}")
sudo docker exec "${container}" wget -q -O /dev/null \
  --header "X-Api-User: $(jq -r .username <<<"${secret}")" \
  --header "X-Api-Key: $(jq -r .password <<<"${secret}")" \
  --post-data "{\"subdomain\": \"$(jq -r .subdomain <<<"${secret}")\", \"txt\": \"${token}\"}" \
  http://auth.rig.invalid:443/update || die "the API refused the token"
name="$(jq -r .subdomain <<<"${secret}").auth.rig.invalid"
txt=$(sudo docker run --rm --network host --entrypoint nslookup "${image}" -type=txt "${name}" 127.0.0.1) ||
  die "port 53 did not answer for ${name}"
grep -qF "${token}" <<<"${txt}" || die "port 53 answered ${name} without the token"
ns=$(sudo docker run --rm --network host --entrypoint nslookup "${image}" -type=ns auth.rig.invalid 127.0.0.1)
grep -qF 'nameserver = ns.rig.invalid' <<<"${ns}" || die "the zone names another nameserver: ${ns}"
echo "10-register.sh: a registration's token is served over port 53, under the zone's NS"
