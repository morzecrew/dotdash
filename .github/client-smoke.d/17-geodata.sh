#!/usr/bin/env bash
# geosite: a geosite.dat of one list, SMOKETEST, which Xray's own lacks, served
# on the stand-in subscription server's own address, which only the stand-in
# dotdash server reaches (as 15-refresh.sh does): the fetch at start, direct,
# fails, the client starts on Xray's own, and the fetch once Xray runs comes
# through dotdash. A direct rule naming SMOKETEST then passes, and unset, the
# client is back on Xray's own. Hand-made in geosite.dat's protobuf form:
# GeoSiteList{GeoSite{"SMOKETEST", Domain{Domain, "smoke.test"}}}.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if sudo grep -q '^  geosite:$' /opt/dotdash-client/current/manifest.yaml; then
  fetch() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 8 --proxy http://127.0.0.1:7890 \
      https://www.gstatic.com/generate_204 || true
  }
  xray_logs() {
    local c
    c=$(sudo docker ps -q --filter label=com.docker.compose.project=dotdash-client \
      --filter label=com.docker.compose.service=xray | sed -n 1p)
    sudo docker logs "${c}" 2>&1
  }
  sub=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-rig-sub)
  [ -n "${sub}" ] || die "the stand-in subscription server has no address"
  printf '\x0a\x1b\x0a\x09SMOKETEST\x12\x0e\x08\x02\x12\x0asmoke.test' | sudo tee /rig/client/www/geosite.dat >/dev/null
  sudo chmod a+r /rig/client/www/geosite.dat
  sum=$(sha256sum /rig/client/www/geosite.dat | cut -d' ' -f1)

  sudo morzer config set geosite="http://${sub}:8080/geosite.dat ${sum}" >/dev/null || die "could not set geosite"
  for _ in $(seq 45); do
    xray_logs | grep -q 'geosite.dat: fetched, its sha256 the pinned one, and the running config passes on it' && break
    sleep 2
  done
  xray_logs | grep -q 'geosite.dat: fetched, its sha256 the pinned one, and the running config passes on it' ||
    { xray_logs | grep 'geodata' | tail -5 >&2; die "the pinned geosite.dat was not fetched through dotdash"; }

  printf 'GEOSITE,smoketest\n' | sudo morzer config set --set-file direct_rules=- >/dev/null ||
    die "a direct rule naming the fetched list was refused"
  for _ in $(seq 30); do [ "$(fetch)" = 204 ] && break; sleep 2; done
  [ "$(fetch)" = 204 ] || die "on the fetched geosite.dat the proxy port does not get out"

  sudo morzer config unset direct_rules >/dev/null
  sudo morzer config unset geosite >/dev/null
  sudo jq -e '[.routing.rules[] | .domain // [] | .[] | select(startswith("geosite:"))] == []' \
    /etc/dotdash-client/config.json >/dev/null || die "a geosite rule remains"
  for _ in $(seq 30); do [ "$(fetch)" = 204 ] && break; sleep 2; done
  [ "$(fetch)" = 204 ] || die "back on Xray's own geodata the proxy port does not get out"
  sudo rm -f /rig/client/www/geosite.dat
  echo "17-geodata.sh: a pinned geosite.dat comes through dotdash, and a rule naming its list passes"
fi
