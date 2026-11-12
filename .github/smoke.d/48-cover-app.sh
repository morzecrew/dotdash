#!/usr/bin/env bash
# An app behind the cover site (cover). With a stand-in app, Caddy's own image
# answering "cover app", on Caddy's network as cover-app:
# - the site's pages are the app's, and a subscription's path stays Caddy's
#   (a guessed one gets the app's answer, as any other path does);
# - doctor passes, and with the app stopped fails, naming it;
# - another, published on a host port only, is reached as host.docker.internal;
# - with cover back to pages, the bundled page is back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

if ! sudo grep -qx '  cover:' /opt/dotdash/current/manifest.yaml; then
  echo "${0##*/}: skipped, the installed release predates cover"
  exit 0
fi

caddy=$(service_container caddy)
domain=$(sudo docker exec "${caddy}" printenv DOMAIN)
image=$(sudo docker inspect -f '{{.Config.Image}}' "${caddy}")
network=$(sudo docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${caddy}" | grep '_edge$')
restore() {
  sudo morzer config set cover=pages >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-cover-app dotdash-rig-host-app >/dev/null 2>&1 || true
}
trap restore EXIT
page() { # <path>: the body Caddy answers on the public port
  curl --noproxy '*' -sk --max-time 10 --resolve "${domain}:443:127.0.0.1" "https://${domain}$1" || true
}

sudo docker run -d --name dotdash-rig-cover-app --network "${network}" --network-alias cover-app \
  "${image}" caddy respond --listen :8080 --body "cover app" >/dev/null
sudo morzer config set cover=http://cover-app:8080 >/dev/null || die "could not set cover"
[ "$(page /)" = "cover app" ] || die "the site is not the app's: $(page / | head -c 200)"
[ "$(page "/$(openssl rand -hex 16)")" = "cover app" ] || die "a guessed subscription path is not passed to the app"
echo "${0##*/}: the site is the app's, a guessed subscription path included"

sudo morzer doctor >/dev/null 2>&1 || die "doctor fails with the app up: $(sudo morzer doctor 2>&1 | tail -5)"
sudo docker stop -t 1 dotdash-rig-cover-app >/dev/null
# doctor wraps a long message over lines: read it as one.
out=$(sudo morzer doctor 2>&1) && die "doctor passes with the app stopped"
out=$(tr -s ' \n' ' ' <<<"${out}")
grep -qF 'app behind the site (cover) does not answer' <<<"${out}" ||
  die "doctor does not name the stopped app: ${out}"
echo "${0##*/}: doctor passes with the app up, and names it once stopped"

# An app on no network of dotdash's, published on a port of the host.
sudo docker run -d --name dotdash-rig-host-app -p 18180:8080 \
  "${image}" caddy respond --listen :8080 --body "host app" >/dev/null
sudo morzer config set cover=http://host.docker.internal:18180 >/dev/null ||
  die "could not point cover at an app published on the host"
[ "$(page /)" = "host app" ] || die "the site is not the host-published app's: $(page / | head -c 200)"
echo "${0##*/}: an app published on a host port is reached as host.docker.internal"

sudo morzer config set cover=pages >/dev/null || die "could not set cover back to pages"
grep -q "<title>${domain}</title>" <<<"$(page /)" || die "with cover=pages, the bundled page is not back"
echo "${0##*/}: with cover=pages, the bundled page is back"
