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
# A LAN device's traffic, with gateway on, takes the same path. The interface
# rules follow the default routes as they change (another network, a
# reconnect). Stopping the service, or leaving the tun profile, takes the
# rules out; after a kill they stay, and nothing but the LAN is reachable
# until they go: sudo ip rule del pref 9001; sudo ip rule del pref 9002 (and
# the same with ip -6).
set -eu

# IPv6's rules too where the kernel has IPv6.
fams=-4
[ ! -e /proc/net/if_inet6 ] || fams="-4 -6"

off() {
	for fam in $fams; do
		while ip "$fam" rule del pref 9000 2>/dev/null; do :; done
		ip "$fam" rule del pref 9001 2>/dev/null || true
		ip "$fam" rule del pref 9002 2>/dev/null || true
		ip "$fam" route flush table 9002 2>/dev/null || true
	done
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

on() { # in the order that leaves Xray's own connections working throughout
	off
	sync
	for fam in $fams; do
		ip "$fam" rule add pref 9001 lookup main suppress_prefixlength 0
		ip "$fam" route add unreachable default table 9002
		ip "$fam" rule add pref 9002 lookup 9002
	done
}

case ${1:-run} in
off) off ;;
run)
	on
	trap 'off; exit 0' TERM INT
	echo "killswitch: on; nothing leaves around TUN but Xray's own connections"
	while :; do
		sleep 5 &
		wait $! || true
		sync
	done
	;;
*) echo "killswitch.sh [run|off]" >&2; exit 2 ;;
esac
