#!/bin/sh
# The tun profile's kill switch: with Xray gone (a crash, or a restart on a new
# subscription), its TUN interface and the routes into it go too, and the
# machine's default route would carry everything around dotdash. These rules
# stop that, and stay while Xray comes and goes:
#
#   9000  a socket bound to an interface that holds a default route (Xray's
#         own, which autoOutboundsInterface binds to it) looks up main as is;
#   9001  everything else looks up main without its default routes, so it
#         takes TUN's half routes while they are there, and the networks this
#         machine is on, but never the default route;
#   9002  and what that leaves is unreachable.
#
# And DNS, which 9001 would let reach a resolver on a network the machine is
# on, such as the router DHCP named: nft's table inet dotdash sends DNS (port
# 53, TCP and UDP) to any resolver not on this machine to 192.0.2.53 (or
# 2001:db8::53), a documentation address that TUN's half routes take, where
# Xray answers it with fake addresses; with TUN gone it is unreachable (9002).
# The machine's own DNS (output), from a socket that names its link too, as
# systemd-resolved's do, and what it forwards (prerouting): its containers',
# and a LAN's with gateway on. Xray's own is left as it is: Xray runs in group
# 65531 (compose/tun.yaml). A resolver on this machine (systemd-resolved's
# stub, dns_listen) answers as it is, and what it asks in turn is redirected.
#
# A LAN device's traffic, with gateway on, takes the same path. `run` puts
# back what is missing every 5 s, and the interface rules follow the default
# routes as they change (another network, a reconnect). The rules stay when
# the service stops, so an update, a restart or `morzer stop` never opens the
# machine: `clean`, which the base files run as this service
# (compose/compose.yaml), takes them out once the tun profile is left. By
# hand, as root: ip rule del pref 9001; ip rule del pref 9002 (and the same
# with ip -6); nft delete table inet dotdash.
set -eu

# IPv6's rules too where the kernel has IPv6.
fams=-4
[ ! -e /proc/net/if_inet6 ] || fams="-4 -6"

dns='table inet dotdash {
	chain output {
		type nat hook output priority dstnat; policy accept;
		meta skgid 65531 return
		fib daddr type local return
		meta l4proto { tcp, udp } th dport 53 dnat ip to 192.0.2.53
		meta l4proto { tcp, udp } th dport 53 dnat ip6 to 2001:db8::53
	}
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		fib daddr type local return
		meta l4proto { tcp, udp } th dport 53 dnat ip to 192.0.2.53
		meta l4proto { tcp, udp } th dport 53 dnat ip6 to 2001:db8::53
	}
}'

del() { # <pref...>: every rule at each pref, both families
	for fam in $fams; do
		for pref in "$@"; do
			while ip "$fam" rule del pref "$pref" 2>/dev/null; do :; done
		done
	done
}

off() {
	# 8996 to 8999: DNS rules a build before nft's table added.
	del 8996 8997 8998 8999 9000 9001 9002
	for fam in $fams; do
		for table in 9002 9003 9004; do
			ip "$fam" route flush table "$table" 2>/dev/null || true
		done
	done
	nft delete table inet dotdash 2>/dev/null || true
}

rule() { # <pref> <selector...>: the rule at pref, unless one is there
	ip "$fam" rule show pref "$1" | grep -q . || ip "$fam" rule add pref "$@"
}

sync() { # the interface rules, one per interface that holds a default route
	for fam in $fams; do
		want=$(ip "$fam" route show default | sed -n 's/.* dev \([^ ]*\).*/\1/p' | grep -vx Meta | sort -u)
		have=$(ip "$fam" rule show pref 9000 | sed -n 's/.* oif \([^ ]*\).*/\1/p' | sort -u)
		for dev in $want; do
			echo "$have" | grep -qx "$dev" || ip "$fam" rule add pref 9000 oif "$dev" lookup main
		done
		for dev in $have; do
			echo "$want" | grep -qx "$dev" || ip "$fam" rule del pref 9000 oif "$dev" lookup main
		done
	done
}

on() { # what is missing, in the order that leaves Xray's own connections working
	sync
	for fam in $fams; do
		rule 9001 lookup main suppress_prefixlength 0
		ip "$fam" route replace unreachable default table 9002
		rule 9002 lookup 9002
	done
	# A table nft refuses leaves the rules in place, and the health check says so.
	nft list table inet dotdash >/dev/null 2>&1 || printf '%s\n' "${dns}" | nft -f - || true
}

trap 'exit 0' TERM INT
case ${1:-run} in
clean)
	off
	echo "killswitch: off; not under the tun profile"
	while :; do
		sleep 3600 &
		wait $! || true
	done
	;;
run)
	echo "killswitch: on; nothing leaves around TUN but Xray's own connections"
	del 8996 8997 8998 8999 # as in off
	while :; do
		on
		sleep 5 &
		wait $! || true
	done
	;;
*) echo "killswitch.sh [run|clean]" >&2; exit 2 ;;
esac
