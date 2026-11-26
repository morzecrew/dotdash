#!/bin/sh
# Prints what each client needs, or only the client named in $1. With
# subscriptions on, that is its subscription URL alone; --full, before the
# name, adds its links and Xray config; --local-auth puts a password on that
# config's local proxy, for apps on the phone that look for one. The output
# is credentials: anyone
# holding it can use this server, so send it only over a channel you would
# send a password on. --check reads the parameters alone and stops: what it
# says on stderr about a relays, pools or cdn_extra line, or any other, fails
# the change that brought it (hooks/healthy lists), where devices would lose
# that line or field.
set -eu
# shellcheck source=common.sh
. /task/common.sh
full=false
local_auth=false
check=false
while :; do
  case ${1:-} in
  --full) full=true ;;
  --local-auth) full=true local_auth=true ;;
  --check) check=true ;;
  *) break ;;
  esac
  shift
done
[ "${SUBSCRIPTION:-false}" = true ] || full=true
want=${1:-}
# name_ok <name>: a host name or an IPv4 address, nothing a link or JSON
# would read past. port_ok <port>: a port, as JSON takes a number.
name_ok() { case $1 in '' | .* | *. | *..* | *[!A-Za-z0-9.-]*) return 1 ;; esac; }
port_ok() { case $1 in '' | 0* | *[!0-9]* | ??????*) return 1 ;; esac; [ "$1" -le 65535 ]; }
# A tunnel zone with no dot is a name under the domain, as in the template.
case ${XDNS_DOMAIN:-} in '' | *.*) ;; *) XDNS_DOMAIN=${XDNS_DOMAIN}.${DOMAIN} ;; esac
[ -z "${XDNS_DOMAIN:-}" ] || name_ok "$XDNS_DOMAIN" || { echo "xdns_domain is not a name: ${XDNS_DOMAIN}" >&2; exit 1; }
case ${XDNS_TTI:-50} in '' | *[!0-9]*) echo "xdns_tti is not a number of milliseconds: ${XDNS_TTI}" >&2; exit 1 ;; esac
[ "${XDNS_TTI:-50}" -ge 10 ] && [ "${XDNS_TTI:-50}" -le 1000 ] || { echo "xdns_tti is outside 10 to 1000: ${XDNS_TTI}" >&2; exit 1; }
# xdns_resolvers as a JSON list: udp://, tcp:// or https:// URLs, none with a
# character JSON would need escaped.
xdns_addrs=
for r in $(printf '%s' "${XDNS_RESOLVERS:-udp://1.1.1.1:53}" | tr ',' ' '); do
  case $r in
  udp://* | tcp://* | https://*) ;;
  *) echo "xdns_resolvers takes udp://, tcp:// or https:// URLs: ${r}" >&2; exit 1 ;;
  esac
  case $r in *[\"\\]*) echo "xdns_resolvers: an address with a quote or backslash: ${r}" >&2; exit 1 ;; esac
  xdns_addrs="${xdns_addrs:+${xdns_addrs}, }\"${r}\""
done
[ -n "$xdns_addrs" ] || { echo "xdns_resolvers is empty" >&2; exit 1; }
servers=$(server_list)
count=$(printf '%s\n' "$servers" | grep -c .)
# direct=false: no server's address in anything printed here, so a leaked
# device gives away relays and CDN hosts, never a server. No links or outbounds
# to the servers, no subscription URL on this domain, and no DNS tunnel: its
# zone is delegated to a server, so a lookup of it names the address.
direct=${DIRECT:-true}
# hello_split: the ClientHello of the servers' REALITY outbounds re-wrapped in
# TLS records of 100-200 bytes, sent apart (dotdash-lab #50), for a box that
# blocks the servers' name by SNI without joining TLS records.
split_hello=', "finalmask": {"tcp": [{"type": "fragment", "settings": {"packets": "tlshello", "length": "100-200", "delay": "10-20"}}]}'
hello=
[ "${HELLO_SPLIT:-false}" != true ] || hello=$split_hello
if [ "$direct" = false ]; then servers='' count=0 XDNS_DOMAIN=; fi
# Set by the xhttp-reality profiles' overlay only: XHTTP with REALITY, a third
# link and outbound. Without it the output is what it always was.
xr_port=${XHTTP_REALITY_PORT:-}
# Set by the mkcp profile's overlay only: VLESS over mKCP, on UDP, a link and
# outbound per server after the others. Its packets are encrypted under the
# seed, then start with the header; a client lists both, in that order, as
# v2rayN and v2rayNG do from a link's seed and headerType.
kcp_port=${KCP_PORT:-}
kcp_header=${KCP_HEADER:-dtls}
kcp_open=${KCP_OPEN:-none}
kcp_seed=
[ -z "$kcp_port" ] || kcp_seed=$(cat /run/secrets/kcp_seed)
# Set by the hysteria2 profile's overlay only: Hysteria2, on UDP, a link and
# outbound per server after the others. Its login is the device's UUID, its
# TLS the site's own certificate, so the link carries no key but the name.
hy2_port=${HYSTERIA2_PORT:-}
# kcp_open=quic: a finalmask noise mask sends a QUIC-Initial-shaped packet
# before the flow. headerType cannot carry it, so such a link gives the whole
# mask list in fm= (url-encoded JSON) in place of seed and headerType, and the
# outbound appends the mask to its list. The packet is a fixed shape; tune it
# on a canary.
# ponytail: a static opener is replayable; a per-device or rotated shape if DPI starts matching it.
kcp_noise='{"type": "noise", "settings": {"noise": [{"type": "hex", "packet": "c300000001088394c8f03e5157080000449e00000002", "delay": "0-0"}]}}'
kcp_masks() { # <seed> <header> [open]: an mKCP outbound's finalmask list
  printf '{"type": "mkcp-legacy", "settings": {"value": "%s"}}' "$1"
  [ "$2" = none ] || printf ', {"type": "mkcp-legacy", "settings": {"header": "%s"}}' "$2"
  [ "${3:-none}" != quic ] || printf ', %s' "$kcp_noise"
}
pct() { # <JSON of dotdash's own>: url-encoded for a link, what JSON holds and a URL may not
  printf '%s' "$1" | sed \
    -e 's/%/%25/g' -e 's/{/%7B/g' -e 's/}/%7D/g' -e 's/"/%22/g' \
    -e 's/:/%3A/g' -e 's/,/%2C/g' -e 's/\[/%5B/g' -e 's/\]/%5D/g' -e 's/ /%20/g'
}
fm_enc() { # <seed> <header> <open>: the finalmask object, url-encoded for a link's fm=
  pct "$(printf '{"udp": [%s]}' "$(kcp_masks "$1" "$2" "$3")")"
}
enc=$(/opt/xray/xray-entrypoint vless-encryption /run/secrets/vless_seed)
path=$(cat /run/secrets/xhttp_path)
sid=$(cat /run/secrets/reality_short_id)
pbk=$(/opt/xray/xray-entrypoint reality-password /run/secrets/reality_key)
# The dotdash-relay machines in front of this server (the relays parameter),
# one "<host> <site> <public key> <short id> <encryption> [own-site [<xhttp
# path>]] [kcp=<port>,<header>,<seed>[,<open>]] [hy2=<port>] [cdn=<host>[,<host>]]
# [cdnpath=<path>] [origin=<host>[/<path>][,<host>[/<path>]]] [cdn-only] [off=<path>[,<path>]] [split] [name=<label>]
# [standby]" per
# line; blank lines, "#" comments and shorter lines are not relays. own-site:
# the site is the relay's own, which fetches subscriptions from here and, given
# its path, routes XHTTP to the relay's Xray. kcp=: the relay serves mKCP on
# that UDP port too, with the opener <open> (quic) if it names one. hy2=: an
# own-site relay serves Hysteria2 on that UDP port, under its site's
# certificate. cdn=:
# local CDNs front the relay's own site, as cdn_hosts fronts this server's;
# they need its XHTTP path. cdnpath=: the relay serves CDNs on a path of its
# own, disguised for a CDN (its CDN inbound), which its CDN links then take,
# so a CDN never learns the path devices reach the relay by directly; without
# it they take that one, plain. cdn-only: devices get the relay's CDN links alone,
# so its own address reaches none of them. off=: the paths its canaries find
# blocked (reality, xhttp, mkcp, hysteria2; dotdash-manager sets it), which devices then
# don't get through it; its CDN links stay. split: its canaries got REALITY
# through only with its hello split into TLS records (dotdash-manager sets it):
# the Xray config devices get keeps a REALITY outbound through it, split, even
# with off=reality, which share links can't carry. name=: the operator's
# label for the relay (its name parameter), which its links carry in place of
# "relay <n>"; one an earlier relay took is left out, so names stay unique.
# standby: devices hold the relay's links but use them only when every other
# fails, and don't check them meanwhile, so the relay carries nothing while
# the rest get through: its share links come last, and in the Xray config its
# outbounds come first, outside the dotdash- tags the balancer and the checks
# take, where Xray sends what the balancer can't place.
# origin=: the names of a rented CDN that ends TLS at its edge and fetches
# the relay in plain HTTP through its door (the relay's http-origin profile),
# on the CDN path: more of its CDN hosts, whose links upload in 4 KiB GETs.
# A name may carry a path, which its links take in place of the CDN path: a
# gateway's own, which it turns back into the relay's on the way.
# Each becomes a row of the columns in cols, "-" for a field it lacks: kp, kh,
# ks and ko kcp='s port, header, seed and opener; d its CDN hosts, the
# origin's among them, comma-separated, which pick then cuts down to a
# device's, and dall all of them; rn its route, which its links are named by;
# or its origin hosts. awk reads $2 the site, $6 own-site, $12 the CDN hosts,
# $13 cdn-only and $19 standby.
cols='h s k i e o p kp kh ks ko d only off sp hy rn cp sb or dall'
# fronts_ok <list>: whether it is "<host>[/<path>]", comma-separated.
fronts_ok() {
  case $1 in '' | ,* | *, | *,,*) return 1 ;; esac
  for fe in $(printf '%s' "$1" | tr ',' ' '); do
    fh=${fe%%/*}
    name_ok "$fh" || return 1
    case ${fe#"$fh"} in *[!A-Za-z0-9._~/-]*) return 1 ;; esac
  done
}
# shellcheck disable=SC2030 # its columns, which the readers of the rows name too
all_relays=$(set -f; n=0; printf '%s\n' "${RELAYS:-}" | while read -r line; do
  n=$((n + 1))
  case $line in '' | '#'*) continue ;; esac
  c=- d=- only=- x=- sp=- hy=- nm=- cp=- sb=- or=- rest=
  for f in $line; do
    case $f in kcp=*) c=${f#kcp=} ;; hy2=*) hy=${f#hy2=} ;; cdn=*) d=${f#cdn=} ;; cdnpath=*) cp=${f#cdnpath=} ;; origin=*) or=${f#origin=} ;; cdn-only) only=cdn-only ;; off=*) x=${f#off=} ;; split) sp='split' ;; name=*) nm=${f#name=} ;; standby) sb=standby ;;
      # No other field holds "=": a typo, such as cdn_path=, would drop a transport unsaid.
      *=*) case ${f%%=*} in *[!A-Za-z0-9_-]*) k='?' ;; *) k=${f%%=*} ;; esac
        echo "relays: line $n: no field is named $k=; ignored" >&2 ;;
      *) rest="$rest $f" ;; esac
  done
  # shellcheck disable=SC2086 # one field per word
  set -- $rest
  [ -n "${5:-}" ] || continue
  # Each field Xray or a link reads: one that could close its string, or that
  # a device's Xray would refuse along with its whole config, leaves the line
  # out, so a tampered line can neither rewrite nor break every device's.
  # Checked last to first, so the first bad one is named.
  why=
  [ "${6:-}" != own-site ] || case ${7:-} in *[!0-9a-f]*) why='XHTTP path' ;; esac
  case $5 in none | mlkem768x25519plus.*) ;; *) why=encryption ;; esac
  case $5 in *[!A-Za-z0-9._-]*) why=encryption ;; esac
  case $4 in '' | *[!0-9a-f]*) why='short id' ;; esac
  [ ${#4} -le 16 ] || why='short id'
  case $3 in *[!A-Za-z0-9_-]*) why='public key' ;; esac
  [ ${#3} = 43 ] || why='public key'
  name_ok "$2" || why=site
  # The host may be an IPv6 address too.
  name_ok "$1" || case $1 in *:*:*) case $1 in *[!0-9A-Fa-f:.]*) why=host ;; esac ;; *) why=host ;; esac
  if [ -n "$why" ]; then
    echo "relays: line $n: its $why is malformed; left out" >&2
    continue
  fi
  # kcp=<port>,<header>,<seed>[,quic], whole, in its parts.
  kp=- kh=- ks=- ko=-
  case $c in -) ;; *)
    kp=${c%%,*}; kh=${c#*,}; ks=${kh#*,}; kh=${kh%%,*}; ko=none ok=true
    case $ks in *,quic) ks=${ks%,quic} ko=quic ;; esac
    port_ok "$kp" || ok=false
    case $kh in none | dtls | srtp | utp | wechat | wireguard) ;; *) ok=false ;; esac
    case $ks in '' | *[!0-9a-f]*) ok=false ;; esac
    $ok || {
      echo "relays: line $n: the kcp= field of $1 is not <port>,<header>,<seed>[,<open>]; no mKCP link through it" >&2
      kp=-; } ;;
  esac
  o=${6:-} p=${7:-}
  if [ "$o" != own-site ]; then o='' p=''; fi
  case $hy in
    -) ;;
    *) if ! port_ok "$hy"; then echo "relays: line $n: the hy2= field of $1 is not a port; no Hysteria2 link through it" >&2; hy=-
       elif [ -z "$o" ]; then echo "relays: line $n: $1 names hy2= but no site of its own, whose certificate Hysteria2 needs; no Hysteria2 link through it" >&2; hy=-; fi ;;
  esac
  case $d in
    -) ;;
    '' | ,* | *, | *,,* | .* | *. | *..* | *,.* | *.,* | *[!A-Za-z0-9.,-]*)
      echo "relays: line $n: the cdn= field of $1 is not <host>[,<host>]; no CDN link through it" >&2
      d=- ;;
    *) [ -n "$p" ] || {
      echo "relays: line $n: $1 names CDNs but no XHTTP path of its own site; no CDN link through it" >&2
      d=-; } ;;
  esac
  case $cp in
    -) ;;
    '' | *[!0-9a-f]*) echo "relays: line $n: the cdnpath= field of $1 is not hex; its CDN links take its XHTTP path" >&2; cp=- ;;
  esac
  case $or in
    -) ;;
    *) if ! fronts_ok "$or"; then
         echo "relays: line $n: the origin= field of $1 is not <host>[/<path>][,<host>[/<path>]]; no link through it" >&2; or=-
       elif [ "$cp" = - ]; then
         echo "relays: line $n: $1 names origin= but no cdnpath=, the path its door passes; no link through it" >&2; or=-
       elif [ "$d" = - ]; then d=$or
       else d="$d,$or"; fi ;;
  esac
  case $x in *[!a-z0-9,-]*) echo "relays: line $n: the off= field of $1 is not <path>[,<path>]; ignored" >&2; x=- ;; esac
  case ,$x, in ,-, | ,,) x=- ;; esac
  case ,$x, in *,mkcp,*) kp=- ;; esac
  case ,$x, in *,hysteria2,*) hy=- ;; esac
  for y in $(printf '%s' "$x" | tr ',' ' '); do
    case $y in - | reality | xhttp | mkcp | hysteria2) ;; *) echo "relays: line $n: the off= field of $1 names $y, not reality, xhttp, mkcp or hysteria2; ignored" >&2 ;; esac
  done
  if [ "$only" = cdn-only ] && [ "$d" = - ]; then
    echo "relays: line $n: $1 is cdn-only but has no CDN link; left out" >&2
    continue
  fi
  case $nm in
    -) ;;
    '' | ?????????????????????????* | *[!A-Za-z0-9._-]*)
      echo "relays: line $n: the name= field of $1 is not 1 to 24 letters, digits, dots, dashes or underscores; it goes by its number" >&2
      nm=- ;;
    *) case " ${taken:-} " in *" $nm "*)
      echo "relays: line $n: $1 is named $nm, as an earlier relay is; it goes by its number" >&2
      nm=- ;;
    esac ;;
  esac
  taken="${taken:-} $nm"
  echo "$1 $2 $3 $4 $5 ${o:--} ${p:--} $kp $kh $ks $ko $d $only $x $sp $hy $nm $cp $sb $or $d"
done)
# A relay's route, unnamed: "relay", numbered where there are several by its
# place among the lines (a host's first), the same on every device.
[ -z "$all_relays" ] || all_relays=$(printf '%s\n' "$all_relays" | awk '{ r[NR] = $0; if (!($1 in at)) at[$1] = NR }
  END { for (n = 1; n <= NR; n++) { $0 = r[n]; if ($17 == "-") $17 = (NR > 1 ? "relay%20" at[$1] : "relay"); print } }')

# The local CDNs in front of this server (the cdn_hosts parameter), each
# fronting https://${DOMAIN}, and the path they fetch XHTTP by, to its CDN
# inbound, disguised as a relay's CDN path is: a CDN, which reads every
# request, never learns xhttp_path.
all_cdns=$(hosts cdn_hosts "${CDN_HOSTS:-none}")
cdn_path=
[ -z "$all_cdns" ] || cdn_path=$(cat /run/secrets/cdn_xhttp_path)

# The pools parameter: one "<pool> <member>..." line per pool, the members
# device names, relay hosts and CDN hosts, a relay's own included. A device in
# a pool gets its pools' relays and CDN hosts and those in no pool; a device in
# none gets them all. A relay's CDN hosts go only to devices that get the
# relay. A leaked device then gives away its pools' entry points, not every one.
pools=$(printf '%s\n' "${POOLS:-}" | sed 's/#.*//' | awk 'NF > 1')
has() { # <member> <pool lines>: whether a line lists it
  printf '%s\n' "$2" | awk -v m="$1" '{ for (i = 2; i <= NF; i++) if ($i == m) f = 1 } END { exit !f }'
}
sees() { [ -z "$mine" ] || has "$1" "$mine" || ! has "$1" "$pools"; }
# A desktop (the kind after a device's name in vless_clients) gets no CDN
# link: CDNs are for the restricted mobile networks, some paid by the GB, and
# a desktop moves the most. So no cdn_hosts, no relay's cdn= or origin=, and
# no cdn-only relay, which would give it nothing. Any other kind, or none,
# gets them all.
# shellcheck disable=SC2030,SC2031,SC2086,SC2154,SC2229 # read -r $cols sets each column
pick() { # <device name> [<kind>]: the relays, CDN hosts and subscription relays it gets
  mine=
  [ -z "$1" ] || mine=$(printf '%s\n' "$pools" | awk -v m="$1" '{ for (i = 2; i <= NF; i++) if ($i == m) { print; next } }')
  relays=$(printf '%s\n' "$all_relays" | while read -r $cols; do
    if [ -z "$h" ] || ! sees "$h"; then continue; fi
    if [ "${2:-}" = desktop ]; then
      [ "$only" != cdn-only ] || continue
      d=-
    fi
    if [ "$d" != - ]; then
      d=$(for x in $(printf '%s' "$d" | tr ',' ' '); do if sees "${x%%/*}"; then printf '%s,' "$x"; fi; done)
      d=${d%,}
    fi
    echo "$h $s $k $i $e $o $p $kp $kh $ks $ko ${d:--} $only $off $sp $hy $rn $cp $sb $or $dall"
  done)
  cdns=
  [ "${2:-}" = desktop ] || cdns=$(for h in $all_cdns; do if sees "$h"; then echo "$h"; fi; done)
  # The own-site relays' domains, where a device inside the restricted network
  # fetches its subscription; not a cdn-only one's, whose address stays out.
  sub_relays=$(printf '%s\n' "$relays" | awk '$6 == "own-site" && $13 != "cdn-only" { print $2 }')
}
# A member that names nothing would leave its device in no pool, or its relay
# or CDN host in none, and so seen by every device: say so.
names=$(awk '$1 !~ /^#/ && NF > 1 { print $2 }' /run/secrets/vless_clients)
relay_names=$(printf '%s\n' "$all_relays" | awk '{ print $1; if ($12 != "-") { gsub(",", "\n", $12); gsub("/[^\n]*", "", $12); print $12 } }')
printf '%s\n' "${POOLS:-}" | sed 's/#.*//' | awk 'NF > 1 { for (i = 2; i <= NF; i++) print NR, $i }' | while read -r n m; do
  printf '%s\n%s\n%s\n' "$names" "$all_cdns" "$relay_names" | grep -qxF -- "$m" ||
    echo "pools: line $n: $m is no device name, relay host or CDN host" >&2
done
# Their edges take GET alone and no request body (some answer 413 to any),
# so a device uploads in packet-up GETs with the data in headers. The server's
# inbound reads that as it is: its placement is auto. Edges cap a request's
# headers at about 20 KB (431 past it), so a GET carries 8 KiB at most: some
# 11 KB once base64-encoded, in one header, with room for the rest. The
# link's extra is the five keys a phone's importer was seen to take, with
# uplinkChunkSize a string, percent-encoded; cdn_outbound sets the same.
link_extra() { # <chunk> <post> [<disguise>]: a CDN link's extra
  pct "{\"scMaxEachPostBytes\":$2,\"scMinPostsIntervalMs\":10,\"uplinkChunkSize\":\"$1\",\"uplinkDataPlacement\":\"header\",\"uplinkHTTPMethod\":\"GET\"${3:+,$(printf '%s' "$3" | sed 's/": /":/g; s/, "/,"/g')}}"
}
cdn_extra=$(link_extra 16384 8192)
# Through a relay's CDN path (cdnpath=), the same, disguised as its CDN
# inbound expects (the relay's xray.json.tmpl; a mismatch is a 400): the
# session, sequence and padding in cookies, the padding a random token, the
# upload under X-Part, so a CDN's logs show one path and no X-Padding, no
# Referer full of X and no X-Data.
cdn_disguise='"uplinkDataKey": "X-Part", "xPaddingBytes": "64-256", "xPaddingObfsMode": true, "xPaddingMethod": "tokenish", "xPaddingPlacement": "cookie", "xPaddingKey": "csrftoken", "sessionIDPlacement": "cookie", "sessionIDKey": "sessionid", "seqPlacement": "cookie", "seqKey": "seq"'
cdn_disguised_extra=$(link_extra 16384 8192 "$cdn_disguise")
# Through a rented CDN at a relay's door (origin=): plain, as its edges
# forward headers past which 8 KiB uploads fail, so 4 KiB each, in 4 KiB
# chunks.
origin_extra=$(link_extra 4096 4096)
# cdn_extra: "<host> <JSON object>", the object across lines if need be: the
# XHTTP extra a CDN or a gateway in front asks for, as it gives it. Links and
# outbounds through that host carry it whole in place of dotdash's own, which
# Xray then reads alone, but for the path, host and mode (packet-up). One
# Xray refuses is left out, as a device's Xray would refuse its whole config
# over it.
# ponytail: braces are counted, so a "{" or "}" inside a JSON string breaks
# the object across lines; one line holds any.
cdn_extras=$(printf '%s\n' "${CDN_EXTRA:-none}" | awk '
  !depth && /^[ \t]*(#|$)/ { next }
  !depth { h = $1; n = NR; sub(/^[ \t]*[^ \t]+[ \t]*/, ""); j = "" }
  { sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); j = j $0; t = $0; depth += gsub(/[{]/, "", t); t = $0; depth -= gsub(/[}]/, "", t) }
  !depth { print n, h, j }
  END { if (depth) print n, h, j }' | while read -r n h j; do
  case $h in none) continue ;; esac
  # Not what it holds, which may be anything of the object's.
  name_ok "$h" || { echo "cdn_extra: line $n: it does not start with a host name; left out" >&2; continue; }
  case $j in '{'*'}') ;; *) echo "cdn_extra: line $n: the extra for $h is not a JSON object; dotdash's own through it" >&2; continue ;; esac
  printf '{"outbounds": [{"protocol": "vless", "settings": {"address": "%s", "port": 443, "id": "00000000-0000-0000-0000-000000000000", "encryption": "none"}, "streamSettings": {"network": "xhttp", "security": "tls", "xhttpSettings": {"path": "/", "mode": "packet-up", "extra": %s}}}]}' "$h" "$j" |
    /opt/xray/xray run -test -config stdin: >/dev/null 2>&1 ||
    { echo "cdn_extra: line $n: Xray refuses the extra for $h; dotdash's own through it" >&2; continue; }
  echo "$h $j"
done)
# Percent-encoded whole, for a link.
uri() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g'; }
# Each host's object (extra_<n>) and the same for a link (extra_uri_<n>),
# made once here, not for every device.
xn=0 extra_hosts=
while read -r h j; do
  [ -n "$h" ] || continue
  xn=$((xn + 1)) extra_hosts="$extra_hosts $h"
  eval "extra_$xn=\$j extra_uri_$xn=\$(uri \"\$j\")"
done <<EOF
$cdn_extras
EOF
extra_of() { # <host>: its cdn_extra object in ex, for a link in exu; empty for a host it names not
  ex= exu= xn=0
  for eh in $extra_hosts; do
    xn=$((xn + 1))
    [ "$eh" = "$1" ] || continue
    eval "ex=\$extra_$xn exu=\$extra_uri_$xn"
    return 0
  done
}

# support-x25519mlkem768: mihomo strips the X25519MLKEM768 key share unless a
# link asks for it, and Xray's REALITY refuses a client without it. Other
# clients look up the parameters they know and pass over this one.
# XHTTP first, then REALITY: an app tends to try the first link it holds, and
# REALITY with Vision over raw TCP is the transport blocked most often. REALITY
# stays, for networks where XHTTP is the one that fails. XHTTP links keep
# mode auto: measured on wire-sized captures with a round trip, packet-up was
# flagged no less often (neither was, by nDPI or the lab's classifier) and
# loaded pages up to an eighth slower.
# Each link is named "<route> · <transport>": the route "server", a relay's
# name= or "relay", and the transport reality, xhttp, kcp, hy2, or "cdn" for
# XHTTP through a CDN, in front of this server or of the relay. The device's
# own name is left out: its subscription is its own. Each is numbered only
# where there are several: "server <n>" with several servers, "relay <n>" with
# several relays lines, "cdn <n>" with several cdn_hosts or several cdn= hosts
# on the relay. The numbers are a server's place in servers, a relay's among
# the relays lines, and a CDN's in cdn_hosts or among its relay's cdn= hosts:
# the same on every device, whichever of them its pools give it, and no host
# name shows in the app.
sep='%20%C2%B7%20'
# is_origin <origin hosts|-> <cdn host>: whether that CDN host is one of the
# relay's door's (origin=), whose links upload in 4 KiB GETs.
is_origin() { case ,$1, in *,"$2",*) return 0 ;; esac; return 1; }
# " <n>", percent-encoded, or nothing when cdn_hosts holds one.
cdn_no() { printf '%s\n' "$all_cdns" | awk -v h="$1" '$0 == h && !n { n = NR } END { if (NR > 1) printf "%%20%d", n }'; }

# One link printer per transport, for the servers and the relays alike: <id>
# <address> <port> <encryption> and the transport's own, then the route the
# link is named by and where it goes, as its description says it.
link_xhttp() { # <id> <address> <port> <encryption> <name> <path> <route> <where>
  cat <<EOF
XHTTP over TLS $8:
vless://$1@$2:$3?encryption=$4&security=tls&sni=$5&host=$5&alpn=h2&fp=chrome&type=xhttp&path=%2F$6&mode=auto#$7${sep}xhttp

EOF
}
link_reality() { # <id> <address> <port> <encryption> <name> <public key> <short id> <route> <where>
  cat <<EOF
REALITY $9 (v2rayN, v2rayNG, Hiddify, Happ, Streisand, mihomo):
vless://$1@$2:$3?encryption=$4&flow=xtls-rprx-vision&security=reality&sni=$5&fp=chrome&pbk=$6&sid=$7&support-x25519mlkem768=true&type=tcp#$8${sep}reality

EOF
}
link_kcp() { # <id> <address> <port> <encryption> <header> <seed> <open> <route> <where>
  if [ "$7" = quic ]; then ko_say=', QUIC-shaped opening' kq="fm=$(fm_enc "$6" "$5" quic)"
  else ko_say= kq="headerType=$5&seed=$6"; fi
  cat <<EOF
mKCP $9, on UDP port $3${ko_say} (v2rayN, v2rayNG):
vless://$1@$2:$3?encryption=$4&type=kcp&${kq}#$8${sep}kcp

EOF
}
link_hy2() { # <id> <address> <port> <name> <route> <where>
  cat <<EOF
Hysteria2 $6, on UDP port $3 (Happ, v2rayN, v2rayNG, Hiddify, Streisand, mihomo, sing-box):
hysteria2://$1@$2:$3/?sni=$4#$5${sep}hy2

EOF
}
link_cdn() { # <id> <cdn> <encryption> <path> <origin|disguised|-> <route> <number> <in front of>: XHTTP through a CDN, as cdn_outbound
  extra_of "$2"
  case $5 in origin) le=$origin_extra ;; disguised) le=$cdn_disguised_extra ;; *) le=$cdn_extra ;; esac
  [ -z "$ex" ] || le=$exu
  case $4 in */*) lp=$(printf '%s' "$4" | sed 's#/#%2F#g') ;; *) lp=$4 ;; esac
  cat <<EOF
XHTTP through the CDN $2$8 (v2rayN, v2rayNG, Happ):
vless://$1@$2:443?encryption=$3&security=tls&sni=$2&host=$2&alpn=h2&fp=chrome&type=xhttp&path=%2F${lp}&mode=packet-up&extra=${le}#$6${sep}cdn$7

EOF
}

links() { # <id> <device> <server> <route>: each named "<route> · <transport>"
  link_xhttp "$1" "$3" "$HTTPS_PORT" "$enc" "$3" "$path" "$4" "via $3 (for a CDN in front: replace the address with the CDN's name)"
  [ -z "$xr_port" ] || cat <<EOF
XHTTP with REALITY via $3, on port ${xr_port} (v2rayN, v2rayNG, mihomo):
vless://$1@$3:${xr_port}?encryption=${enc}&security=reality&sni=$3&fp=chrome&pbk=${pbk}&sid=${sid}&support-x25519mlkem768=true&type=xhttp&path=%2F${path}&mode=auto#$4${sep}xhttp%2Breality

EOF
  link_reality "$1" "$3" "$HTTPS_PORT" "$enc" "$3" "$pbk" "$sid" "$4" "via $3"
  [ -z "$kcp_port" ] || link_kcp "$1" "$3" "$kcp_port" "$enc" "$kcp_header" "$kcp_seed" "$kcp_open" "$4" "via $3"
  [ -z "$hy2_port" ] || link_hy2 "$1" "$3" "$hy2_port" "$3" "$4" "via $3"
}

# blocked <off field> <path>: whether a relay's off= field names the path.
blocked() { case ,$1, in *,"$2",*) ;; *) return 1 ;; esac; }

# relay_cdn <cdn host[/path]>: a relay row's CDN host's address (xh), path
# (xp) and shape (kind): through its door (origin=) plain in 4 KiB, by a path
# of the name's own where it has one; else by its CDN path, disguised, where it
# names one (cdnpath=); else by its XHTTP path, plain.
# shellcheck disable=SC2031 # the row its caller read
relay_cdn() {
  xh=${1%%/*} xp=$p kind=-
  if is_origin "$or" "$1"; then
    kind=origin xp=$cp
    [ "$xh" = "$1" ] || xp=${1#*/}
  elif [ "$cp" != - ]; then kind=disguised xp=$cp; fi
}

# A relay takes REALITY on 443 under its neighbour site's name, with keys of its
# own, and carries the device on to this server as its own client.
# shellcheck disable=SC2031,SC2086,SC2154,SC2229 # read -r $cols sets each column
relay_links() { # <id> <device> <normal|standby>: per relay of that group, "<route> · reality", with "xhttp" and each CDN's "cdn[ <m>]" before it through an own-site one, "hy2" and "kcp" after it with Hysteria2 and mKCP
  printf '%s\n' "$relays" | while read -r $cols; do
    [ -n "$h" ] || continue
    if [ "$sb" = standby ]; then [ "$3" = standby ] || continue; else [ "$3" = normal ] || continue; fi
    [ "$p" = - ] || [ "$only" = cdn-only ] || blocked "$off" xhttp ||
      link_xhttp "$1" "$h" 443 "$e" "$s" "$p" "$rn" "through the relay $h, behind its own site (v2rayN, v2rayNG, Happ)"
    # The device's CDNs, each numbered by its place among all the relay's.
    m=0
    [ "$d" = - ] || for x in $(printf '%s' "$dall" | tr ',' ' '); do
      m=$((m + 1))
      case ,$d, in *,"$x",*) ;; *) continue ;; esac
      no=
      case $dall in *,*) no="%20$m" ;; esac
      relay_cdn "$x"
      link_cdn "$1" "$xh" "$e" "$xp" "$kind" "$rn" "$no" ", in front of the relay $h"
    done
    [ "$only" != cdn-only ] || continue
    blocked "$off" reality || link_reality "$1" "$h" 443 "$e" "$s" "$k" "$i" "$rn" "through the relay $h"
    [ "$hy" = - ] || link_hy2 "$1" "$h" "$hy" "$s" "$rn" "through the relay $h"
    [ "$kp" = - ] || link_kcp "$1" "$h" "$kp" "$e" "$kh" "$ks" "$ko" "$rn" "through the relay $h"
  done
}

cdn_links() { # <id> <device>: one per CDN, named "server · cdn[ <n>]"
  for h in $cdns; do
    link_cdn "$1" "$h" "$enc" "$cdn_path" disguised server "$(cdn_no "$h")" ''
  done
}

# Every TCP link gives a connection up once what it sent has gone
# unacknowledged for 15 s (tcpUserTimeout), and redials. A censor that freezes
# a connection sends nothing back, and XHTTP sends every request down the
# connection it holds: a minute with no answer at all, 17 s with this, and a
# lossy link never trips it (dotdash-lab #57).
uto=', "sockopt": {"tcpUserTimeout": 15000}'

# One outbound printer per transport, as the link printers: <tag> <id>
# <address> <port> <encryption> and the transport's own.
cdn_outbound() { # <tag> <id> <cdn> <encryption> <path> [disguised|origin|-]: XHTTP through a CDN, uploading by GET with the data in headers, or as cdn_extra has it
  more='' chunk=16384 post=8192
  [ "${6:-}" != disguised ] || more=", ${cdn_disguise}"
  [ "${6:-}" != origin ] || chunk=4096 post=4096
  xs="\"uplinkHTTPMethod\": \"GET\", \"uplinkDataPlacement\": \"header\", \"uplinkChunkSize\": ${chunk},
         \"scMaxEachPostBytes\": ${post}, \"scMinPostsIntervalMs\": 10${more}"
  extra_of "$3"
  [ -z "$ex" ] || xs="\"extra\": $ex"
  cat <<EOF
    {"tag": "$1", "protocol": "vless",
     "settings": {"address": "$3", "port": 443, "id": "$2", "encryption": "$4"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$3", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/$5", "host": "$3", "mode": "packet-up",
         ${xs}}${uto}}},
EOF
}

cdn_outbounds() { # <id>
  n=0
  for h in $cdns; do
    n=$((n + 1))
    cdn_outbound "dotdash-cdn-$n" "$1" "$h" "${enc}" "${cdn_path}" disguised
  done
}

# On a Vision link, a device's UDP flows share a few connections (XUDP Mux)
# rather than open one each: one connection for 20 flows instead of 20, the
# first answer in one round trip rather than three (dotdash-lab #51). TCP stays
# off Mux, as Vision needs (concurrency -1); QUIC to UDP 443 is turned away,
# so a browser goes over TCP inside the tunnel, as Vision would have it.
mux='"mux": {"enabled": true, "concurrency": -1, "xudpConcurrency": 8, "xudpProxyUDP443": "reject"}'

ob_reality() { # <tag> <id> <address> <port> <encryption> <name> <public key> <short id> <hello split|>
  cat <<EOF
    {"tag": "$1", "protocol": "vless",
     "settings": {"address": "$3", "port": $4, "id": "$2", "encryption": "$5", "flow": "xtls-rprx-vision"},
     "streamSettings": {"network": "raw", "security": "reality",
       "realitySettings": {"serverName": "$6", "fingerprint": "chrome", "password": "$7", "shortId": "$8"}$9${uto}},
     ${mux}},
EOF
}
ob_xhttp() { # <tag> <id> <address> <port> <encryption> <name> <path>
  cat <<EOF
    {"tag": "$1", "protocol": "vless",
     "settings": {"address": "$3", "port": $4, "id": "$2", "encryption": "$5"},
     "streamSettings": {"network": "xhttp", "security": "tls",
       "tlsSettings": {"serverName": "$6", "alpn": ["h2"], "fingerprint": "chrome"},
       "xhttpSettings": {"path": "/$7", "host": "$6", "mode": "auto"}${uto}}},
EOF
}
ob_kcp() { # <tag> <id> <address> <port> <encryption> <header> <seed> <open>
  cat <<EOF
    {"tag": "$1", "protocol": "vless",
     "settings": {"address": "$3", "port": $4, "id": "$2", "encryption": "$5"},
     "streamSettings": {"network": "kcp", "finalmask": {"udp": [$(kcp_masks "$7" "$6" "$8")]}}},
EOF
}
# Hysteria2 under the site's own name, keepalives every 10 s.
ob_hy2() { # <tag> <id> <address> <port> <name>
  cat <<EOF
    {"tag": "$1", "protocol": "hysteria",
     "settings": {"version": 2, "address": "$3", "port": $4},
     "streamSettings": {"network": "hysteria", "security": "tls",
       "tlsSettings": {"serverName": "$5", "alpn": ["h3"]},
       "hysteriaSettings": {"version": 2, "auth": "$2"},
       "finalmask": {"quicParams": {"keepAlivePeriod": 10}}}},
EOF
}

# shellcheck disable=SC2031,SC2086,SC2154,SC2229 # read -r $cols sets each column
relay_outbounds() { # <id> <own|cdn> <normal|standby>: that group's relays' own outbounds, or their CDNs'
  n=0
  printf '%s\n' "$relays" | while read -r $cols; do
    [ -n "$h" ] || continue
    n=$((n + 1))
    # standby: outside dotdash-, which the balancer and the checks take.
    pre=dotdash
    if [ "$sb" = standby ]; then [ "$3" = standby ] || continue; pre=standby; else [ "$3" = normal ] || continue; fi
    if [ "$2" = cdn ]; then
      m=0
      [ "$d" = - ] || for x in $(printf '%s' "$d" | tr ',' ' '); do
        m=$((m + 1))
        # dotdash-cdn-, as the servers' CDNs: apart from the relay's own
        # dotdash-relay-<n>, so a client can leave every CDN out by prefix
        # (dotdash-client's cdn=skip), Xray's only way to pick outbounds.
        relay_cdn "$x"
        cdn_outbound "${pre}-cdn-relay-$n-$m" "$1" "$xh" "$e" "$xp" "$kind"
      done
      continue
    fi
    # split: REALITY through it with its hello split, even with off=reality.
    rhello=
    [ "$sp" != split ] || rhello=$split_hello
    [ "$only" = cdn-only ] || { blocked "$off" reality && [ "$sp" != split ]; } ||
      ob_reality "${pre}-relay-$n" "$1" "$h" 443 "$e" "$s" "$k" "$i" "$rhello"
    [ "$p" = - ] || [ "$only" = cdn-only ] || blocked "$off" xhttp || ob_xhttp "${pre}-relay-$n-xhttp" "$1" "$h" 443 "$e" "$s" "$p"
    [ "$hy" = - ] || [ "$only" = cdn-only ] || ob_hy2 "${pre}-relay-$n-hy2" "$1" "$h" "$hy" "$s"
    [ "$kp" != - ] && [ "$only" != cdn-only ] || continue
    ob_kcp "${pre}-relay-$n-kcp" "$1" "$h" "$kp" "$e" "$kh" "$ks" "$ko"
  done
}

# Every CDN's outbound after every other: Xray sends what its balancer can't
# place to the first outbound, which is then never a CDN's while any other is.
outbounds() { # <id>: the standby relays', then a REALITY and an XHTTP outbound per server, the third, mKCP, the relays, the CDNs
  n=0
  { relay_outbounds "$1" own standby; relay_outbounds "$1" cdn standby
  for s in $servers; do
    n=$((n + 1))
    ob_reality "dotdash-$n-reality" "$1" "$s" "$HTTPS_PORT" "$enc" "$s" "$pbk" "$sid" "$hello"
    ob_xhttp "dotdash-$n-xhttp" "$1" "$s" "$HTTPS_PORT" "$enc" "$s" "$path"
    [ -z "$xr_port" ] || cat <<EOF
    {"tag": "dotdash-$n-xhttp-reality", "protocol": "vless",
     "settings": {"address": "$s", "port": ${xr_port}, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "xhttp", "security": "reality",
       "realitySettings": {"serverName": "$s", "fingerprint": "chrome", "password": "${pbk}", "shortId": "${sid}"},
       "xhttpSettings": {"path": "/${path}", "mode": "auto"}${uto}}},
EOF
    [ -z "$kcp_port" ] || ob_kcp "dotdash-$n-kcp" "$1" "$s" "$kcp_port" "$enc" "$kcp_header" "$kcp_seed" "$kcp_open"
    [ -z "$hy2_port" ] || ob_hy2 "dotdash-$n-hy2" "$1" "$s" "$hy2_port" "$s"
  done; relay_outbounds "$1" own normal; cdn_outbounds "$1"; relay_outbounds "$1" cdn normal; } | sed '$ s/,$//'
}

xdns_outbound() { # <id>: the DNS tunnel, for the config's last resort, its queries spread over xdns_resolvers
  cat <<EOF
    {"tag": "xdns", "protocol": "vless",
     "settings": {"address": "1.1.1.1", "port": 53, "id": "$1", "encryption": "${enc}"},
     "streamSettings": {"network": "kcp", "kcpSettings": {"mtu": 130, "tti": ${XDNS_TTI:-50}},
       "finalmask": {"udp": [{"type": "xdns", "settings": {
         "domains": [{"names": ["${XDNS_DOMAIN}"], "edns0": 1232}],
         "resolvers": [{"addrs": [${xdns_addrs}]}]}}]}}}
EOF
}

sub_through() { # <token>: the same subscription through each own-site relay
  for r in $sub_relays; do
    printf 'through the relay %s: https://%s/%s\n' "$r" "$r" "$1"
  done
}

client() { # <id> <label>
  echo "== $2 =="
  if [ "${SUBSCRIPTION:-false}" = true ]; then
    # As subscription.sh names the device's file.
    token=$(printf '%s:%s' "$(cat /run/secrets/subscription_key)" "$1" | sha256sum | cut -c1-32)
    if [ "${HTTPS_PORT}" = 443 ]; then at=; else at=":${HTTPS_PORT}"; fi
    own="https://${DOMAIN}${at}/${token}"
    [ "$direct" != false ] || own=
    [ -n "$own$sub_relays" ] ||
      echo "$2: no subscription URL: direct=false keeps this server's out, and the device gets no own-site relay" >&2
    if ! $full; then
      [ -z "$own" ] || echo "$own"
      sub_through "$token"
      echo
      return 0
    fi
    [ -z "$own$sub_relays" ] || cat <<EOF
Subscription, for the app to fetch these links from and refresh them after a
revocation or a key rotation (as secret as the links):
EOF
    [ -z "$own" ] || echo "$own"
    sub_through "$token"
    [ -z "$own" ] || [ -z "$sub_relays" ] || echo "An app takes one: a device inside the restricted network gets one through a relay."
    echo
  fi
  if [ "$direct" = false ] && [ -z "$relays" ] && [ -z "$cdns" ]; then
    echo "$2: no links: direct=false keeps the servers out, and the device gets no relay or CDN host" >&2
    return 0
  fi
  n=0
  for s in $servers; do
    n=$((n + 1))
    if [ "$count" -gt 1 ]; then at="server%20$n"; else at=server; fi
    links "$1" "$2" "$s" "$at"
  done
  relay_links "$1" "$2" normal
  cdn_links "$1" "$2"
  # The standby relays' last: an app tends to try the first links it holds.
  relay_links "$1" "$2" standby
  if [ "$count" -gt 1 ]; then where=" on any of the servers"; else where=; fi
  if [ "$direct" = false ]; then which=
  elif [ -n "$xr_port" ]; then which="REALITY, XHTTP and XHTTP with REALITY"
  else which="REALITY and XHTTP"; fi
  [ -z "$kcp_port" ] || [ "$direct" = false ] || which="${which}, or mKCP"
  [ -z "$hy2_port" ] || [ "$direct" = false ] || which="${which}, or Hysteria2"
  [ -z "$relays" ] || which="${which:+${which}, or }a relay"
  [ -z "$cdns" ] || which="${which:+${which}, or }XHTTP through a CDN"
  case $which in *', or '*) which="${which}," ;; esac
  # The standby relays' outbounds come first, where Xray sends what the
  # balancer can't place, so they take over only when no other answers; the
  # DNS tunnel's fallback would come before them, so it is left out then.
  if [ -n "$(printf '%s\n' "$relays" | awk '$19 == "standby"')" ]; then
    last=", and the standby relays only when none answers"
    fallback=''
  elif [ -n "${XDNS_DOMAIN:-}" ]; then
    last=", and the DNS tunnel only when none answers"
    fallback=', "fallbackTag": "xdns"'
  else
    last='' fallback=''
  fi
  # --local-auth: a password on the local SOCKS, the same on every run (a
  # hash of the device's id, which reveals nothing of it), and no
  # HTTP inbound, which the app's VPN mode never uses. Any other app on the
  # phone otherwise finds an open proxy there and, through it, the exit.
  if $local_auth; then
    pass=$(printf 'dotdash local proxy:%s' "$1" | sha256sum | cut -c1-32)
    inbounds="{\"listen\": \"127.0.0.1\", \"port\": 10808, \"protocol\": \"socks\",
     \"settings\": {\"udp\": true, \"auth\": \"password\", \"accounts\": [{\"user\": \"dotdash\", \"pass\": \"${pass}\"}]},
     \"sniffing\": {\"enabled\": true, \"destOverride\": [\"fakedns\"]}}"
    intro="Xray client config, for v2rayNG as a custom config. Its local SOCKS
(10808) takes the user dotdash and the password ${pass}:
enter both in v2rayNG's settings (Local proxy username and password), or the
device gets nowhere."
  else
    inbounds="{\"listen\": \"127.0.0.1\", \"port\": 10808, \"protocol\": \"socks\", \"settings\": {\"udp\": true},
     \"sniffing\": {\"enabled\": true, \"destOverride\": [\"fakedns\"]}},
    {\"listen\": \"127.0.0.1\", \"port\": 10809, \"protocol\": \"http\"}"
    intro="Xray client config, for v2rayN or v2rayNG as a custom config (local SOCKS on
10808, HTTP on 10809)."
  fi
  cat <<EOF
${intro}
It uses whichever of ${which} answers fastest${where}${last}.
DNS the device sends on port 53, in the app's VPN or TUN mode, gets a stand-in
IPv4 address at once (fake DNS), and the server looks the name up when the
connection reaches it; a link leaves DNS to the app's own settings:
{
  "dns": {"servers": ["fakedns"], "queryStrategy": "UseIPv4"},
  "fakedns": [{"ipPool": "198.18.0.0/15", "poolSize": 65535}],
  "inbounds": [
    ${inbounds}
  ],
  "outbounds": [
$(outbounds "$1")$([ -z "${XDNS_DOMAIN:-}" ] || printf ',\n%s' "$(xdns_outbound "$1")"),
    {"tag": "dns-out", "protocol": "dns"}
  ],
  "burstObservatory": {"subjectSelector": ["dotdash-"], "pingConfig": {"destination": "https://www.gstatic.com/generate_204", "interval": "30s", "sampling": 1}},
  "routing": {
    "balancers": [{"tag": "dotdash", "selector": ["dotdash-"], "strategy": {"type": "leastPing"}${fallback}}],
    "rules": [
      {"type": "field", "port": "53", "outboundTag": "dns-out"},
      {"type": "field", "network": "tcp,udp", "balancerTag": "dotdash"}
    ]
  }
}

EOF
}

! $check || exit 0
$full || cat <<EOF
Subscription URLs, one per device, for v2rayN, v2rayNG, Hiddify, Happ or
Streisand to fetch its links from and refresh them; --full prints the links
and the Xray config too.

EOF
# One client per line, "<uuid> [name [desktop|mobile]]"; blank lines and "#"
# comments skipped, as the image reads it. $1 names one client, or gives its
# uuid.
found=
while read -r id name kind _ || [ -n "${id:-}" ]; do
  case $id in '' | '#'*) continue ;; esac
  [ -z "$want" ] || [ "$want" = "${name:-}" ] || [ "$want" = "$id" ] || continue
  found=1
  pick "${name:-}" "${kind:-}"
  client "$id" "${name:-client}"
done </run/secrets/vless_clients
[ -n "$found" ] || { echo "no client named '$want' in vless_clients" >&2; exit 1; }

$full && [ -n "${XDNS_DOMAIN:-}" ] || exit 0
cat <<EOF
The config's "xdns" outbound, the DNS tunnel, is slow, for networks where only
DNS works. Its resolvers are the server's xdns_resolvers; where the network
allows another, replace them, or set xdns_resolvers for every device. DoH
("https://...") or "tcp://" also work. Its "address" must be an IP: XDNS sends
through the resolvers, not to it. UDP is dropped unless the upstream is SOCKS5
with upstream_udp=true, so point the client's DNS at DoH or TCP and lookups
ride the tunnel.
EOF
