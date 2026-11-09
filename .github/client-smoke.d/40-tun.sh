#!/usr/bin/env bash
# The tun profile: a plain request on the machine, with no proxy settings,
# goes through dotdash; with dotdash gone, nothing gets out directly instead;
# and back on the base files, the machine's own routes are as before. First,
# the two configs differ only where TUN needs them to.
#
# TUN binds mihomo's own dials to the main interface, so this stand-in sits on
# the rig's own network, reached over eth0, with a subscription of its link
# there too (a real dotdash server is reached the same way). It resolves
# tun-target.test to the subscription server's address on docker0 (pre-apply/
# 10-server.sh), a connected network TUN leaves alone, so its own way there
# doesn't loop back in, and the name resolves nowhere else: a plain request
# that reaches it went through TUN and dotdash. A REALITY server dials its
# target (www.gstatic.com) on every handshake, a dial TUN would take back to
# the stand-in itself, so a direct rule sends that one around dotdash.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

a=$(sudo jq -S 'del(.ipv6, .listeners, .tun, .dns)' /etc/dotdash-client/config.json)
b=$(sudo jq -S 'del(.ipv6, .listeners, .tun, .dns)' /etc/dotdash-client/config-tun.json)
[ "${a}" = "${b}" ] || die "config-tun.json differs from config.json beyond ipv6, listeners, tun and dns: $(diff <(echo "${a}") <(echo "${b}") | head -20)"

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
eth0=$(ip -4 -o addr show eth0 | awk '{ sub("/.*", "", $4); print $4 }')
target=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-rig-sub)
dir=/rig/client/tun
sudo mkdir -p "${dir}/server" "${dir}/www"
jq --arg target "${target}" '.inbounds[0].port = 9444 | .dns = {hosts: {"tun-target.test": $target}}
  | .outbounds[0].streamSettings = {sockopt: {domainStrategy: "UseIPv4"}}' /rig/client/server/config.json \
  | sudo tee "${dir}/server/config.json" >/dev/null
base64 -d </rig/client/www/sub | sed "s/@${host}:9443/@${eth0}:9444/" | base64 -w0 | sudo tee "${dir}/www/sub" >/dev/null
sudo chmod -R a+rX "${dir}"
sudo docker run -d --name client-rig-tun-server --network host -v "${dir}/server:/etc/xray:ro" "${xray}" >/dev/null
sudo docker run -d --name client-rig-tun-sub --network host -v "${dir}/www:/www:ro" "${busybox}" \
  httpd -f -p 8089 -h /www >/dev/null

plain() { # <URL>: its status from the rig with no proxy, or 000
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "$1" || true
}
home=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash-client_home)

# Its subscription, a probe the stand-in answers, the direct rule, and no
# cached links.
printf 'http://%s:8089/sub' "${eth0}" | sudo morzer secret set subscription_url >/dev/null
printf 'DOMAIN,www.gstatic.com\n' | sudo morzer secret set direct_rules >/dev/null
sudo morzer config set probe_url=http://tun-target.test:8080/sub >/dev/null
sudo rm -f "${home}/proxies/dotdash.yaml"
sudo morzer config set installation.profile=tun >/dev/null
ip -o link show Meta >/dev/null 2>&1 || die "under the tun profile there is no TUN interface"

code=000
for _ in $(seq 15); do
  code=$(plain http://tun-target.test:8080/sub)
  [ "${code}" = 200 ] && break
  sleep 2
done
[ "${code}" = 200 ] || die "a plain request did not go through TUN and dotdash (${code})"

sudo docker stop client-rig-tun-server >/dev/null
for _ in 1 2 3; do
  code=$(plain https://example.com/)
  [ "${code}" != 200 ] || die "with dotdash gone, a plain request got out directly"
  sleep 2
done
sudo docker start client-rig-tun-server >/dev/null

sudo morzer config unset installation.profile >/dev/null
ip -o link show Meta >/dev/null 2>&1 && die "back on the base files, the TUN interface is still there"
printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
sudo morzer config unset probe_url >/dev/null
printf '# none\n' | sudo morzer secret set direct_rules >/dev/null
sudo rm -f "${home}/proxies/dotdash.yaml"
sudo docker restart "$(service_container mihomo)" >/dev/null
sudo docker rm -f client-rig-tun-server client-rig-tun-sub >/dev/null
[ "$(plain https://www.gstatic.com/generate_204)" = 204 ] || die "back on the base files, the rig's own requests don't get out"
echo "40-tun.sh: under tun, plain requests go through dotdash and never around it; back to the base files cleanly"
