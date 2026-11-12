#!/usr/bin/env bash
# What the server tells an authority it follows (manifest `published`): the
# facts task's JSON names this server as its devices' links do, carries the
# public key they carry, and none of their credentials.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -q '^  facts:$' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates it"
  exit 0
fi

facts=$(sudo morzer task run facts --output) || die "the facts task failed"
jq -e . >/dev/null <<<"${facts}" || die "the facts are not JSON: ${facts}"
domain=$(jq -r .domain <<<"${facts}")
link=$(sudo morzer task run client-config --output -- --full | grep 'security=reality' | grep -m1 -F "@${domain}:") ||
  die "client-config printed no REALITY link to ${domain}, the facts' domain"
param() { sed -n "s/.*[?&]$1=\([^&#]*\).*/\1/p" <<<"${link}"; }

[ "$(jq -r .public_key <<<"${facts}")" = "$(param pbk)" ] || die "the facts' public key is not the links' pbk"
jq -e '.https_port | type == "number"' >/dev/null <<<"${facts}" || die "https_port is not a number"
jq -e '.encryption | startswith("mlkem768x25519plus.")' >/dev/null <<<"${facts}" || die "the facts carry no VLESS encryption string"
sid=$(param sid)
[ -n "${sid}" ] || die "the REALITY link has no sid to look for"
! grep -qF "${sid}" <<<"${facts}" || die "the facts carry the short id, a credential"
echo "${0##*/}: facts name the server, carry its public key and encryption, and no short id"
