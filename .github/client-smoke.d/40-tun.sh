#!/usr/bin/env bash
# The tun profile: a plain request on the machine, with no proxy settings,
# goes through dotdash, and so does a LAN device's with this machine as its
# gateway; a start with no links gets its subscription; DNS to a LAN
# resolver goes into TUN; with dotdash gone,
# with Xray itself gone, and with the kill switch stopped too, nothing gets out
# directly instead; and back on the base files, the machine's own routes are
# as before.
#
# TUN binds Xray's own sockets to the main interface, so this stand-in sits on
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

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
caddy=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/caddy-acmedns | sed -n 1p)
host=$(ip -4 -o addr show docker0 | awk '{ sub("/.*", "", $4); print $4 }')
eth0=$(ip -4 -o addr show eth0 | awk '{ sub("/.*", "", $4); print $4 }')
target=$(sudo docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' client-rig-sub)
dir=/rig/client/tun
sudo mkdir -p "${dir}/server" "${dir}/www" "${dir}/caddy"
jq --arg target "${target}" '.inbounds[0].port = 9444 | .dns = {hosts: {"tun-target.test": $target}}
  | .outbounds[0].streamSettings = {sockopt: {domainStrategy: "UseIPv4"}}' /rig/client/server/config.json \
  | sudo tee "${dir}/server/config.json" >/dev/null
base64 -d </rig/client/www/sub | sed "s/@${host}:9443/@${eth0}:9444/" | base64 -w0 | sudo tee "${dir}/www/sub" >/dev/null
jq --arg eth0 "${eth0}" '.outbounds[0].settings.address = $eth0 | .outbounds[0].settings.port = 9444' \
  /rig/client/www/sub.json | sudo tee "${dir}/www/sub.json" >/dev/null
sed 's/^:8080 {/:8089 {/' /rig/client/caddy/Caddyfile | sudo tee "${dir}/caddy/Caddyfile" >/dev/null
sudo chmod -R a+rX "${dir}"
sudo docker run -d --name client-rig-tun-server --network host -v "${dir}/server:/etc/xray:ro" \
  -v /rig/client/secrets:/run/secrets:ro "${xray}" >/dev/null
sudo docker run -d --name client-rig-tun-sub --network host -v "${dir}/caddy:/etc/caddy:ro" -v "${dir}/www:/www:ro" \
  "${caddy}" >/dev/null

plain() { # <URL>: its status from the rig with no proxy, or 000
  curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "$1" || true
}
through() { # <tries>: poll, 2 s apart, for a plain request reaching tun-target.test through TUN and dotdash
  for _ in $(seq "$1"); do [ "$(plain http://tun-target.test:8080/sub)" = 200 ] && return 0; sleep 2; done
  return 1
}
routes() { # what decides where a plain request goes, for a failure's message
  { echo "--- ip rule"; ip rule; echo "--- ip route"; ip route; echo "--- ip -6 route"; ip -6 route
    echo "--- table 9003"; ip route show table 9003 2>&1
    echo "--- resolv.conf"; cat /etc/resolv.conf; echo "--- tun-target.test"; getent hosts tun-target.test || true; } >&2
}
home=$(sudo docker volume inspect -f '{{.Mountpoint}}' dotdash-client_home)

# ip netns, for the gateway's LAN device below; fetched now, as under TUN the
# rig's own requests reach no further than tun-target.test.
sudo apk add -q iproute2 >/dev/null || die "apk add iproute2 failed"

# Its subscription, the direct rule, no cached links, and a probe the stand-in
# answers. The cache goes before the probe moves: morzer (0.16) health-checks
# that change, and the cached links are the old stand-in's, which resolves no
# tun-target.test; with none, Xray starts on the new subscription.
printf 'http://%s:8089/sub' "${eth0}" | sudo morzer secret set subscription_url >/dev/null
printf 'DOMAIN,www.gstatic.com\n' | sudo morzer config set --set-file direct_rules=- >/dev/null
sudo rm -f "${home}/subscription_url.json"
sudo morzer config set probe_url=http://tun-target.test:8080/sub >/dev/null
sudo morzer config set installation.profile=tun >/dev/null
ip -o link show Meta >/dev/null 2>&1 || die "under the tun profile there is no TUN interface"

through 15 || { routes; die "a plain request did not go through TUN and dotdash ($(plain http://tun-target.test:8080/sub))"; }

# A fresh install, or a cache whose server is gone: no cached links, and a
# subscription that fails at start (404 here), so Xray starts with none. Its
# refresh goes through the sub port, directly from Xray's socket outside TUN
# while no link answers. A real server would send the entrypoint's own direct
# fetch into TUN and to block; this one is local and would answer it, so the
# log tells which way the links came. Meanwhile no other process on the
# machine gets out through that port.
client=$(service_container xray)
sudo mv "${dir}/www/sub.json" "${dir}/www/sub.json.off"
sudo rm -f "${home}/subscription_url.json"
since=$(date +%s)
sudo docker restart "${client}" >/dev/null
for _ in $(seq 30); do sudo docker logs --since "${since}" "${client}" 2>&1 | grep -qE 'no outbounds yet|outbound\(s\)' && break; sleep 1; done
sudo docker logs --since "${since}" "${client}" 2>&1 | grep -q 'no outbounds yet' \
  || die "with the subscription failing at start, Xray did not start with no links: $(sudo docker logs --since "${since}" "${client}" 2>&1 | tail -5)"
sleep 3 # Xray's inbounds up
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -x "socks5h://127.0.0.1:7892" "http://${eth0}:8089/sub" || true)
[ "${code}" != 200 ] || die "with no links, a process on the machine got out directly through the sub port"
since=$(date +%s)
sudo mv "${dir}/www/sub.json.off" "${dir}/www/sub.json"
through 30 || { routes; die "with no links under tun, the subscription never came back"; }
if sudo docker logs --since "${since}" "${client}" 2>&1 | grep -q 'through XRAY_SUBSCRIPTION_PROXY'; then
  die "under tun with no links, the subscription came by the entrypoint's direct fetch, not through the sub port"
fi

# DNS to a resolver on a network the machine is on, here the subscription
# server's address on docker0, where nothing answers on port 53, goes into TUN
# too and gets a fake address, the answer passing the kernel's check of its
# way back, though it comes in on TUN.
out=$(sudo -u nobody nslookup example.com "${target}" 2>&1 || true)
grep -q 'Address:.*198\.1[89]\.' <<<"${out}" || { routes; die "DNS to a resolver on the LAN went around TUN: ${out}"; }

# A gateway. A LAN device, a network namespace behind a veth with this machine
# as its gateway (as in the router spike, #50), first resolves with a public
# resolver, whose queries TUN hijacks, then with dns_listen on the gateway's
# own address. FORWARD's policy is DROP, as Docker sets it on many hosts:
# until the two DOCKER-USER rules are in, doctor names them, and the device
# gets nothing rather than going around dotdash.
sudo ip netns add lan
sudo ip link add lanbr type veth peer name lanif
sudo ip link set lanif netns lan
sudo ip addr add 10.99.0.1/24 dev lanbr && sudo ip link set lanbr up
sudo ip netns exec lan ip addr add 10.99.0.2/24 dev lanif
sudo ip netns exec lan ip link set lanif up && sudo ip netns exec lan ip link set lo up
sudo ip netns exec lan ip route add default via 10.99.0.1
sudo mkdir -p /etc/netns/lan && echo 'nameserver 1.1.1.1' | sudo tee /etc/netns/lan/resolv.conf >/dev/null
lan() { # <URL>: its status from the LAN device, or 000
  sudo ip netns exec lan curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 10 "$1" || true
}
lan_gets() { # <what>: poll for the LAN device reaching tun-target.test
  for _ in $(seq 15); do [ "$(lan http://tun-target.test:8080/sub)" = 200 ] && return 0; sleep 2; done
  die "$1"
}
policy=$(sudo iptables -S FORWARD | sed -n 's/^-P FORWARD //p')
sudo iptables -P FORWARD DROP
# morzer (0.16) health-checks gateway=true and retries a failing check for
# minutes before undoing it, so the rules go in first; taking them out after
# shows what doctor names.
sudo iptables -I DOCKER-USER -o Meta -j ACCEPT
sudo iptables -I DOCKER-USER -i Meta -j ACCEPT
sudo morzer config set gateway=true >/dev/null || die "with the rules in, gateway=true was refused"
out=$(sudo morzer doctor 2>&1) || die "doctor fails as a gateway with the rules in: ${out}"
lan_gets "with the rules in, the LAN device did not get through TUN and dotdash"
sudo iptables -D DOCKER-USER -o Meta -j ACCEPT
sudo iptables -D DOCKER-USER -i Meta -j ACCEPT
out=$(sudo morzer doctor 2>&1) && die "doctor passes as a gateway whose FORWARD drops the LAN"
tr -s '[:space:]' ' ' <<<"${out}" | grep -qF 'DOCKER-USER -o Meta -j ACCEPT' \
  || die "doctor failed, but not naming the DOCKER-USER rules: ${out}"
[ "$(lan http://tun-target.test:8080/sub)" != 200 ] || die "with FORWARD dropping the LAN, the device still got through"
sudo iptables -I DOCKER-USER -o Meta -j ACCEPT
sudo iptables -I DOCKER-USER -i Meta -j ACCEPT
out=$(sudo morzer doctor 2>&1) || die "doctor fails as a gateway with the rules back: ${out}"
lan_gets "with the rules back, the LAN device did not get through TUN and dotdash"
sudo morzer config set dns_listen=10.99.0.1:53 >/dev/null
echo 'nameserver 10.99.0.1' | sudo tee /etc/netns/lan/resolv.conf >/dev/null
lan_gets "resolving with dns_listen on the gateway, the LAN device did not get through"
sudo morzer config unset dns_listen >/dev/null
sudo morzer config unset gateway >/dev/null
sudo iptables -D DOCKER-USER -o Meta -j ACCEPT
sudo iptables -D DOCKER-USER -i Meta -j ACCEPT
sudo iptables -P FORWARD "${policy}"
sudo ip netns del lan
sudo ip link del lanbr 2>/dev/null || true

through 15 || { routes; die "off the gateway, a plain request did not go through TUN and dotdash"; }
sudo docker stop client-rig-tun-server >/dev/null
for _ in 1 2 3; do
  code=$(plain https://example.com/)
  [ "${code}" != 200 ] || die "with dotdash gone, a plain request got out directly"
  sleep 2
done
sudo docker start client-rig-tun-server >/dev/null
# A probe while the stand-in was down counts the link down until the next,
# but what the balancer can't place takes the first link meanwhile.
through 15 || { routes; die "with dotdash back, a plain request did not go through TUN and dotdash within 30 s"; }

# With Xray itself gone, a crash or the image's restart on a new subscription,
# its TUN and routes go too, and the default route would carry everything: the
# kill switch's rules leave nothing but Xray's own connections reachable.
out=$(sudo morzer doctor 2>&1) || die "doctor fails under tun with the kill switch on: ${out}"
client=$(service_container xray)
sudo docker stop "${client}" >/dev/null
ip -o link show Meta >/dev/null 2>&1 && die "with Xray stopped, its TUN interface is still there"
for _ in 1 2 3; do
  code=$(plain https://example.com/)
  [ "${code}" != 200 ] || { routes; die "with Xray gone, a plain request got out directly"; }
  sleep 2
done
sudo docker start "${client}" >/dev/null
through 15 || { routes; die "with Xray back, a plain request did not go through TUN and dotdash again ($(plain http://tun-target.test:8080/sub))"; }

# An update or a restart stops the kill switch too: its rules stay, so with
# Xray gone as well nothing gets out, and its next start adds none twice.
ks=$(service_container killswitch)
sudo docker stop "${ks}" "${client}" >/dev/null
for pref in 9001 9002; do
  ip rule show pref "${pref}" | grep -q . || { routes; die "with the kill switch stopped, its rule ${pref} went"; }
done
code=$(plain https://example.com/)
[ "${code}" != 200 ] || { routes; die "with the kill switch and Xray stopped, a plain request got out directly"; }
sudo docker start "${ks}" "${client}" >/dev/null
sleep 2
[ "$(ip rule show pref 9001 | grep -c .)" = 1 ] || { routes; die "the kill switch's start added its rules twice"; }
through 15 || { routes; die "with the kill switch and Xray back, a plain request did not go through TUN and dotdash"; }

sudo morzer config unset installation.profile >/dev/null
ip -o link show Meta >/dev/null 2>&1 && die "back on the base files, the TUN interface is still there"
ip rule | grep -qE '^(899[89]|900[0-2]):' && { routes; die "back on the base files, the kill switch's rules are still there"; }
printf 'http://%s:8088/sub' "${host}" | sudo morzer secret set subscription_url >/dev/null
sudo morzer config unset probe_url >/dev/null
sudo morzer config unset direct_rules >/dev/null
sudo rm -f "${home}/subscription_url.json"
sudo docker restart "$(service_container xray)" >/dev/null
sudo docker rm -f client-rig-tun-server client-rig-tun-sub >/dev/null
[ "$(plain https://www.gstatic.com/generate_204)" = 204 ] || die "back on the base files, the rig's own requests don't get out"
echo "40-tun.sh: under tun, plain requests, the machine's and a LAN's, go through dotdash and never around it, with Xray down too; back to the base files cleanly"
