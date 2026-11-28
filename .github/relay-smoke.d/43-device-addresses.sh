#!/usr/bin/env bash
# The device-addresses profile: the facts task, run in Xray's namespace,
# counts how many addresses each device is connected from right now, by
# <device>@<group>, and never carries one. Three copies of 10-through.sh's
# phone, each a container on the relay's own network and so each at an
# address of its own, hold a connection open each: phone@s1 counts 3. Once
# they are gone, phone@s1 is gone too. The rig has no IPv6, so the counting
# filter is checked on a fixed list for a /64 counted once. Without the
# profile, the facts carry no addresses. The rig's relay has no entry_host,
# which facts needs (12-facts.sh): set here, and unset after.
# shellcheck source=/dev/null
. /rig/smoke-lib.sh
set -euo pipefail

xray=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' ghcr.io/morzecrew/xray | sed -n 1p)
busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
phones=(relay-rig-addr-1 relay-rig-addr-2 relay-rig-addr-3)
restore() {
  sudo morzer config unset installation.profile >/dev/null 2>&1 || true
  sudo morzer config unset entry_host >/dev/null 2>&1 || true
  for p in "${phones[@]}"; do sudo docker rm -f "${p}-hold" "${p}" >/dev/null 2>&1 || true; done
}
trap restore EXIT
count() { # phone@s1's addresses in the facts, 0 when it has none
  local facts
  facts=$(sudo morzer task run facts --output) || die "the facts task failed under device-addresses"
  jq -e '.addresses.at | type == "number"' >/dev/null <<<"${facts}" ||
    die "the facts carry no addresses under device-addresses: ${facts}"
  jq '.addresses.devices["phone@s1"] // 0' <<<"${facts}"
}
until_count() { # <n>: phone@s1 counts n within 30 s
  for _ in $(seq 10); do
    got=$(count)
    [ "${got}" = "$1" ] && return 0
    sleep 2
  done
  return 1
}

# The filter, from the installed release's tasks, on Xray's answer for two
# devices: a@s1 at two addresses in one /64, one in another and one IPv4
# address; the gateway's checker, whose name would need escaping, left out.
files=$(sudo docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$(service_container xray)")
filter=$(sudo cat "${files%%/compose/*}/tasks/addresses.jq") || die "no tasks/addresses.jq in the installed release"
got=$(jq -c --argjson at 1 "${filter}" <<<'{"users": [
  {"email": "a@s1", "ips": [{"ip": "2001:db8::1"}, {"ip": "2001:db8::5:6:7"}, {"ip": "2001:db8:0:1::1"}, {"ip": "192.0.2.1"}]},
  {"email": "b@s1", "ips": [{"ip": "192.0.2.1"}]}, {"email": "#check@s1", "ips": [{"ip": "192.0.2.2"}]}]}')
[ "${got}" = '{"at":1,"devices":{"a@s1":3,"b@s1":1}}' ] || die "the filter did not count a /64 once: ${got}"
echo "${0##*/}: an IPv6 /64 counts once, and the checker not at all"

sudo morzer config set entry_host=127.0.0.1 >/dev/null || die "could not set entry_host"
sudo morzer config set installation.profile=device-addresses >/dev/null || die "could not switch to the device-addresses profile"
# Each phone dials the relay's Xray by its service name, and passes what
# reaches its own 127.0.0.1:18090 on to www.gstatic.com:443 through it, which
# holds a silent connection open for a minute or more.
mkdir -p /rig/relay/addr
jq '.outbounds[0].settings.address = "xray"
  | .inbounds = [{listen: "127.0.0.1", port: 18090, protocol: "dokodemo-door",
      settings: {address: "www.gstatic.com", port: 443, network: "tcp"}}]' \
  /rig/relay/phone/config.json >/rig/relay/addr/config.json
chmod -R a+rX /rig/relay/addr
# Each phone's holder, in its namespace, connects once the phone listens and
# sends nothing: its stdin stays open (-i) with nothing on it.
for p in "${phones[@]}"; do
  sudo docker run -d --name "${p}" --network dotdash-relay_default -v /rig/relay/addr:/etc/xray:ro "${xray}" >/dev/null
  sudo docker run -d -i --name "${p}-hold" --network "container:${p}" "${busybox}" \
    sh -c 'until nc 127.0.0.1 18090; do sleep 1; done' >/dev/null
done
until_count 3 || die "three phones, each holding a connection, counted ${got}, not 3"
echo "${0##*/}: under device-addresses, the facts count the phone at its three addresses"

for p in "${phones[@]}"; do sudo docker rm -f "${p}-hold" "${p}" >/dev/null; done
until_count 0 || die "with the phones gone, the phone still counts ${got}"
echo "${0##*/}: with its connections closed, the phone is no longer counted"

sudo morzer config unset installation.profile >/dev/null || die "could not drop the device-addresses profile"
facts=$(sudo morzer task run facts --output) || die "the facts task failed without the profile"
jq -e 'has("addresses") | not' >/dev/null <<<"${facts}" || die "without the profile, the facts still carry addresses"
echo "${0##*/}: without the profile, the facts carry no addresses"
