#!/usr/bin/env bash
# An app behind the cover site (cover). With a stand-in app, Caddy's own image
# answering "cover app", on Caddy's network as cover-app:
# - the site's pages are the app's, and a subscription's path stays Caddy's
#   (a guessed one gets the app's answer, as any other path does), with no
#   Via naming Caddy;
# - doctor passes, and with the app stopped fails, naming it;
# - another, published on a host port only, is reached as host.docker.internal;
# - the app sees the visitor's address, which no visitor and nothing but Xray
#   can set;
# - with cover back to pages, the bundled page is back.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

caddy=$(service_container caddy)
domain=$(sudo docker exec "${caddy}" printenv DOMAIN)
image=$(sudo docker inspect -f '{{.Config.Image}}' "${caddy}")
network=$(sudo docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${caddy}" | grep '_edge$')
restore() {
  sudo morzer config set cover=pages >/dev/null 2>&1 || true
  sudo docker rm -f dotdash-rig-cover-app dotdash-rig-host-app dotdash-rig-xff-app >/dev/null 2>&1 || true
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
! curl --noproxy '*' -sk --max-time 10 -D - -o /dev/null --resolve "${domain}:443:127.0.0.1" "https://${domain}/" | grep -qi '^via:' ||
  die "an answer from the app names Caddy in Via"
echo "${0##*/}: the site is the app's, a guessed subscription path included, and no Via names Caddy"

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

# The visitor's address, which Xray hands Caddy in a PROXY header, reaches
# the app as X-Forwarded-For: neither Xray's nor one the visitor sends. The
# visitor is this host, as the gate sees it. A PROXY header from anywhere
# but Xray, here Caddy's own namespace, is ignored.
sudo docker run -d --name dotdash-rig-xff-app --network "${network}" --network-alias xff-app \
  "${image}" caddy respond --listen :8080 --body '{http.request.header.X-Forwarded-For}' >/dev/null
sudo morzer config set cover=http://xff-app:8080 >/dev/null || die "could not point cover at the address stand-in"
xray_ips=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$(service_container xray)")
seen=$(curl --noproxy '*' -sk --max-time 10 -H 'X-Forwarded-For: 198.51.100.9' --resolve "${domain}:443:127.0.0.1" "https://${domain}/" || true)
[[ ${seen} =~ ^[0-9a-f.:]+$ ]] || die "the app got no visitor's address: ${seen}"
case " ${xray_ips} 198.51.100.9 " in *" ${seen} "*) die "the app sees ${seen}, Xray's address or the one the visitor sent" ;; esac
pid=$(sudo docker inspect -f '{{.State.Pid}}' "$(service_container caddy)")
forged=$(sudo nsenter -t "${pid}" -n curl --noproxy '*' -sk --max-time 10 --haproxy-protocol --haproxy-clientip 203.0.113.9 \
  --resolve "${domain}:443:127.0.0.1" "https://${domain}/" || true)
[ "${forged}" = 127.0.0.1 ] || die "Caddy took a PROXY header from beside Xray: the app saw ${forged}"
echo "${0##*/}: the app sees the visitor's address, and Caddy takes no PROXY header but Xray's"

sudo morzer config set cover=pages >/dev/null || die "could not set cover back to pages"
grep -q "<title>${domain}</title>" <<<"$(page /)" || die "with cover=pages, the bundled page is not back"
echo "${0##*/}: with cover=pages, the bundled page is back"
