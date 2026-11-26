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
# And before them DNS, which 9001 would let reach a resolver on a network
# the machine is on, such as the router DHCP named:
#
#   8996, 8997  DNS (TCP, UDP port 53) looks up 9003, TUN while it is there,
#         whose DNS answers with fake addresses. The kernel's check of the
#         answer's way back (rp_filter) takes it too, or the answer, which
#         comes in on TUN, would be dropped;
#   8998, 8999  and while TUN is gone, any but root's looks up 9004, which is
#         unreachable then. Root's is Xray's own on its way up.
#
# A socket that names its interface, as all of Xray's own do, finds no route
# in 9003 and goes on. So does what systemd-resolved sends a link's own DNS
# servers (hooks/killswitch).
#
# A LAN device's traffic, with gateway on, takes the same path. `run` puts
# back what is missing as links change and every 5 s, and the interface rules
# follow the default routes as they change (another network, a reconnect). The rules stay when
# the service stops, so an update, a restart or `morzer stop` never opens the
# machine: `clean`, which the base files run as this service
# (compose/compose.yaml), takes them out once the tun profile is left. By
# hand, as root: ip rule del pref 9001; ip rule del pref 9002 (and the same
# with ip -6).
set -eu

# IPv6's rules too where the kernel has IPv6.
fams=-4
[ ! -e /proc/net/if_inet6 ] || fams="-4 -6"

off() {
	for fam in $fams; do
		for pref in 8996 8997 8998 8999 9000 9001 9002; do
			while ip "$fam" rule del pref "$pref" 2>/dev/null; do :; done
		done
		for table in 9002 9003 9004; do
			ip "$fam" route flush table "$table" 2>/dev/null || true
		done
	done
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
		if ip link show Meta >/dev/null 2>&1; then
			ip "$fam" route replace default dev Meta table 9003 2>/dev/null || true
			ip "$fam" route flush table 9004 2>/dev/null || true
		else
			ip "$fam" route replace unreachable default table 9004
		fi
		rule 8996 ipproto tcp dport 53 lookup 9003
		rule 8997 ipproto udp dport 53 lookup 9003
		rule 8998 uidrange 1-4294967294 ipproto tcp dport 53 lookup 9004
		rule 8999 uidrange 1-4294967294 ipproto udp dport 53 lookup 9004
		rule 9001 lookup main suppress_prefixlength 0
		ip "$fam" route replace unreachable default table 9002
		rule 9002 lookup 9002
	done
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
	# Again at once when a link comes, goes or changes, as TUN does with
	# Xray, so DNS follows it within a moment; and every 5 s, for the default
	# routes. A monitor that stops ends the service, which restarts with its
	# rules kept. read -t is busybox ash's, the image's sh.
	# shellcheck disable=SC3045
	{ ip monitor link; echo stop; } | while :; do
		on
		line=
		read -r -t 5 line || true
		[ "$line" != stop ] || exit 1
	done &
	wait $!
	;;
*) echo "killswitch.sh [run|clean]" >&2; exit 2 ;;
esac
