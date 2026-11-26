#!/usr/bin/env bash
# client-config.sh, the server's task, run as the task runs it (the Caddy
# image's shell, the Xray image's binaries, the secrets as files) against a
# matrix of parameters, its links and Xray config checked with jq: what the
# rig's smoke would catch only after an install, in seconds and without one.
# Last, a wider matrix's whole output (--full, stdout and stderr) against
# client-config.golden beside this file, so a refactor proves it changes
# nothing; a change meant to show runs it with UPDATE_GOLDEN=1, and the
# golden's diff is the change.
# Run from the repository's root: bash .github/tests/client-config.sh
set -euo pipefail

root=$(pwd)
manifest=bundles/server/manifest.yaml
caddy=$(sed -n 's/^  caddy: *//p' "$manifest")
xray=$(sed -n 's/^  xray: *//p' "$manifest")
[ -n "$caddy" ] && [ -n "$xray" ] || { echo "no caddy or xray image in $manifest" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/secrets" "$work/xray"
c=$(docker create "$xray" x)
docker cp "$c:/usr/local/bin/." "$work/xray/" >/dev/null
docker rm "$c" >/dev/null
# Fixed keys, made for this test alone, so the output is the same on every run.
printf eGYJEdI0OAKHLQTuQH5x2-pr38aFxQxjeZZVz_1552g >"$work/secrets/reality_key"
printf 92b7ec15e80f0b2d47ed1493fb8945880044e6601341069a4bd1567027e73aac7c8a956ee2296c3769a88e4c195a5c92fc0e2267cf8a647a3ce43d4a8efb1a0c >"$work/secrets/vless_seed"
printf ab12 >"$work/secrets/reality_short_id"
printf 'aaaa1111bbbb2222' >"$work/secrets/xhttp_path"
printf seedkcp >"$work/secrets/kcp_seed"
printf subkey >"$work/secrets/subscription_key"
printf 0011223344556677889900aa >"$work/secrets/cdn_xhttp_path"
printf '0593b52c-b345-41cb-96b8-134724f6ca65 phone\n1b2c3d4e-5f60-4718-8a9b-0c1d2e3f4a5b laptop mobile\n# a comment\n2c3d4e5f-6071-4829-9bac-1d2e3f4a5b6c desk desktop\n' >"$work/secrets/vless_clients"
chmod 644 "$work"/secrets/*
# A relay's public key and encryption, in the shapes relay-entry prints.
pbk=_nYApZTt3dznuqLOlXzr0UR_BxEvKRLTLv9dL3qt3Ww
enc=mlkem768x25519plus.native.0rtt.c2VlZA

failed=0
fail() { echo "FAIL: $*" >&2; failed=1; }
cc() { # <env assignments...> -- <client-config arguments...>: its stdout; its stderr in $work/err
  local envs=()
  while [ "$1" != -- ]; do envs+=(-e "$1"); shift; done
  shift
  docker run --rm -v "$work/secrets:/run/secrets:ro" -v "$work/xray:/opt/xray:ro" \
    -v "$root/bundles/server/tasks:/task:ro" -e DOMAIN=s.example.com -e HTTPS_PORT=443 \
    ${envs[@]+"${envs[@]}"} "$caddy" sh /task/client-config.sh "$@" 2>"$work/err"
}
config() { sed -n '/^{$/,/^}$/p'; }
links() { grep -E '^(vless|hysteria2)://' || true; }

echo "== plain: links and an Xray config that parses, two local inbounds"
out=$(cc SUBSCRIPTION=false -- --full phone)
[ "$(printf '%s\n' "$out" | links | wc -l)" -ge 2 ] || fail "plain: fewer than two links"
printf '%s\n' "$out" | config | jq -e '.inbounds | length == 2 and .[0].port == 10808 and .[1].port == 10809' >/dev/null ||
  fail "plain: the config does not parse, or its inbounds are not SOCKS 10808 and HTTP 10809"
plain=$(printf '%s\n' "$out" | config)
out_self=$out

echo "== --local-auth: one inbound with a password, the same each run, the rest unchanged"
a=$(cc SUBSCRIPTION=false -- --local-auth phone | config)
b=$(cc SUBSCRIPTION=false -- --local-auth phone | config)
jq -e '.inbounds | length == 1 and .[0].settings.auth == "password" and (.[0].settings.accounts[0].pass | length) == 32' \
  <<<"$a" >/dev/null || fail "--local-auth: not one SOCKS inbound with a 32-character password"
[ "$a" = "$b" ] || fail "--local-auth: another password on another run"
[ "$(jq -S 'del(.inbounds)' <<<"$a")" = "$(jq -S 'del(.inbounds)' <<<"$plain")" ] ||
  fail "--local-auth: the config changed beyond its inbounds"

relay="203.0.113.7 r.example.com ${pbk} ab12 ${enc} own-site aaaa1111bbbb2222 cdn=cdn.example.net cdnpath=cccc3333dddd4444 origin=o.example.org name=edge"
echo "== a relay with a CDN and a door: the CDN's links disguised, the door's plain in 4 KiB"
out=$(cc SUBSCRIPTION=false "RELAYS=$relay" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-1") | .streamSettings.xhttpSettings |
    .scMaxEachPostBytes == 8192 and .xPaddingObfsMode == true and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "relay: the CDN's outbound is not disguised, 8 KiB, on the CDN path"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-2") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "o.example.org" and .scMaxEachPostBytes == 4096 and .uplinkChunkSize == 4096 and (.xPaddingObfsMode // false) == false
    and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "relay: the door's outbound is not plain, 4 KiB, on the CDN path, to its name"
printf '%s\n' "$out" | links | grep -q '^vless://[^@]*@o\.example\.org:443?.*scMaxEachPostBytes%22%3A4096.*#edge%20%C2%B7%20cdn%202$' ||
  fail "relay: no 4 KiB link through the door, named edge · cdn 2"

echo "== a door with two names: a 4 KiB link and outbound through each, numbered after the CDN's"
out=$(cc SUBSCRIPTION=false "RELAYS=${relay/origin=o.example.org/origin=o.example.org,alt.example.org}" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-3") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "alt.example.org" and .scMaxEachPostBytes == 4096 and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "two door names: the second's outbound is not plain, 4 KiB, on the CDN path, to its name"
for n in '2 o\.example\.org' '3 alt\.example\.org'; do
  printf '%s\n' "$out" | links | grep -q "^vless://[^@]*@${n#* }:443?.*scMaxEachPostBytes%22%3A4096.*#edge%20%C2%B7%20cdn%20${n%% *}\$" ||
    fail "two door names: no 4 KiB link through ${n#* }, named edge · cdn ${n%% *}"
done
out=$(cc SUBSCRIPTION=false "RELAYS=${relay/origin=o.example.org/origin=o.example.org,,x}" -- --full phone)
grep -q "origin= field of 203.0.113.7 is not <host>\[/<path>\]" "$work/err" || fail "a bad door list: not said"

echo "== a door name with a gateway's path, and cdn_extra: links and outbounds take both; one Xray refuses is said, and left out"
extra='alt.example.org {
  "mode": "packet-up",
  "uplinkHTTPMethod": "GET",
  "xPaddingKey": "_t", "xPaddingObfsMode": true
}
# a comment
scdn.example.net {"uplinkHTTPMethod": "GET", "uplinkChunkSize": 2048}
cdn.example.net {"mode": broken}'
out=$(cc SUBSCRIPTION=false CDN_HOSTS=scdn.example.net "RELAYS=${relay/origin=o.example.org/origin=o.example.org,alt.example.org/e/tok/s/}" \
  "CDN_EXTRA=$extra" "POOLS=p1 phone alt.example.org" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-3") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "alt.example.org" and .host == "alt.example.org" and .path == "/e/tok/s/" and .extra.xPaddingKey == "_t"
    and .extra.xPaddingObfsMode == true and .scMaxEachPostBytes == null] == [true]' <<<"$cfg" >/dev/null ||
  fail "gateway path: the outbound is not to alt.example.org on /e/tok/s/ with its extra alone"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-1") | .streamSettings.xhttpSettings.extra.uplinkChunkSize] == [2048]' <<<"$cfg" >/dev/null ||
  fail "cdn_extra: the server's CDN outbound does not carry its extra"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-1") | .streamSettings.xhttpSettings |
    .xPaddingObfsMode == true and .scMaxEachPostBytes == 8192 and .extra == null] == [true]' <<<"$cfg" >/dev/null ||
  fail "cdn_extra: a refused extra was not left out, the CDN's outbound not disguised as before"
grep -q "Xray refuses the extra for cdn.example.net" "$work/err" || fail "cdn_extra: a refused extra not said"
grep -q "pools: alt.example.org" "$work/err" && fail "pools: a door name with a path not taken as a member"
link=$(printf '%s\n' "$out" | links | grep '^vless://[^@]*@alt\.example\.org:443?.*sni=alt\.example\.org&host=alt\.example\.org&.*path=%2Fe%2Ftok%2Fs%2F&.*#edge%20%C2%B7%20cdn%203$') ||
  fail "gateway path: no link through alt.example.org on its path, named edge · cdn 3"
e=$(printf '%s' "$link" | sed -n 's/.*[?&]extra=\([^&#]*\).*/\1/p')
printf '%b' "${e//%/\\x}" | jq -e '.xPaddingKey == "_t" and .uplinkHTTPMethod == "GET"' >/dev/null ||
  fail "gateway path: the link's extra is not cdn_extra's, percent-encoded"

echo "== a desktop: no CDN link or outbound, the server's or a relay's, and nothing through a cdn-only relay"
only="203.0.113.9 q.example.com ${pbk} ab12 ${enc} own-site aaaa1111bbbb2222 cdn=cdn2.example.net cdn-only name=hidden"
envs=(SUBSCRIPTION=false CDN_HOSTS=scdn.example.net "RELAYS=$relay
$only")
out=$(cc "${envs[@]}" -- --full desk)
[ -z "$(printf '%s\n' "$out" | links | grep -E '@(scdn|cdn|cdn2|o)\.example\.(net|org):|@203\.0\.113\.9:')" ] ||
  fail "desktop: a CDN link, or one through the cdn-only relay"
printf '%s\n' "$out" | links | grep -q '^vless://[^@]*@203\.0\.113\.7:443?.*security=reality.*#edge%20%C2%B7%20reality$' ||
  fail "desktop: no REALITY link through the relay"
printf '%s\n' "$out" | config | jq -e '[.outbounds[].tag | select(test("cdn"))] == []' >/dev/null ||
  fail "desktop: a CDN outbound in the config"
out=$(cc "${envs[@]}" -- --full phone)
[ "$(printf '%s\n' "$out" | links | grep -cE '@(scdn|cdn|cdn2|o)\.example\.(net|org):')" = 4 ] ||
  fail "a device of no kind: not every CDN link"

echo "== origin= without cdnpath=: said, and no link through it"
out=$(cc SUBSCRIPTION=false "RELAYS=203.0.113.7 r.example.com ${pbk} ab12 ${enc} own-site aaaa1111bbbb2222 origin=o.example.org" -- --full phone)
grep -q "names origin= but no cdnpath=" "$work/err" || fail "origin without cdnpath: not said"
printf '%s\n' "$out" | links | grep -q '@o\.example\.org:' && fail "origin without cdnpath: a link through it anyway"

echo "== pools: a device in a pool gets its pool's relay and those in none"
two="203.0.113.7 a.example.com ${pbk} ab12 ${enc}
203.0.113.8 b.example.com ${pbk} ab12 ${enc}
203.0.113.9 c.example.com ${pbk} ab12 ${enc}"
pools="p1 phone 203.0.113.7
p2 laptop 203.0.113.8"
hosts() { config | jq -r '[.outbounds[].settings.address // empty] | unique | join(" ")'; }
p=$(cc SUBSCRIPTION=false "RELAYS=$two" "POOLS=$pools" -- --full phone | hosts)
l=$(cc SUBSCRIPTION=false "RELAYS=$two" "POOLS=$pools" -- --full laptop | hosts)
for h in 203.0.113.7 203.0.113.9; do
  case " $p " in *" $h "*) ;; *) fail "pools: phone lacks $h, its pool's relay or the free one: $p" ;; esac
done
case " $p " in *" 203.0.113.8 "*) fail "pools: phone gets laptop's pool's relay: $p" ;; esac
case " $l " in *" 203.0.113.8 "*) ;; *) fail "pools: laptop lacks its pool's relay: $l" ;; esac

echo "== a standby relay: outside dotdash-, first among the outbounds"
cfg=$(cc SUBSCRIPTION=false "RELAYS=203.0.113.7 a.example.com ${pbk} ab12 ${enc}
203.0.113.8 b.example.com ${pbk} ab12 ${enc} standby" -- --full phone | config)
jq -e '.outbounds[0].tag | startswith("standby")' <<<"$cfg" >/dev/null || fail "standby: not the first outbound"
jq -e '[.outbounds[].tag | select(startswith("dotdash-relay"))] | length >= 1' <<<"$cfg" >/dev/null ||
  fail "standby: the normal relay's outbound is missing"

echo "== the server's CDN hosts: an 8 KiB GET link and outbound each, disguised on the CDN path"
out=$(cc SUBSCRIPTION=false CDN_HOSTS=cdn1.example.net,cdn2.example.net -- --full phone)
[ "$(printf '%s\n' "$out" | config | jq '[.outbounds[] | select(.tag | startswith("dotdash-cdn-")) | .streamSettings.xhttpSettings |
  select(.scMaxEachPostBytes == 8192 and .uplinkHTTPMethod == "GET" and .path == "/0011223344556677889900aa"
    and .xPaddingObfsMode == true and .sessionIDPlacement == "cookie")] | length')" = 2 ] ||
  fail "cdn_hosts: not two 8 KiB GET outbounds, disguised on the CDN path"
[ "$(printf '%s\n' "$out" | links | grep -c '^vless://[^@]*@cdn[12]\.example\.net:443?.*&path=%2F0011223344556677889900aa&.*xPaddingObfsMode%22%3Atrue.*#server%20%C2%B7%20cdn%20[12]$')" = 2 ] ||
  fail "cdn_hosts: not two links on the CDN path, disguised"
out=$(cc SUBSCRIPTION=false 'CDN_HOSTS=cdn1.example.net,c"x' -- --full phone)
grep -qF 'cdn_hosts: c"x is not a host name; left out' "$work/err" || fail "cdn_hosts: a malformed name not said"
grep -qF 'c"x' <<<"$out" && fail "cdn_hosts: a malformed name not left out"

echo "== a malformed relays line: left out by its line number, the good lines' output byte-identical"
good="$relay
203.0.113.9 c.example.com ${pbk} 0123456789abcdef none kcp=9448,wireguard,abcdef,quic hy2=8443 off=reality"
# The encryption closing its string to set another address, and the same
# with balanced braces adding a dotdash- outbound; then a bad site, key,
# short id, encryption and XHTTP path. Last, so every good line keeps its number.
bad="$good
# bad lines
203.0.113.20 r2.example.com ${pbk} ab12 none\",\"address\":\"evil.example
203.0.113.21 r3.example.com ${pbk} ab12 none\"},\"streamSettings\":{}},{\"tag\":\"dotdash-evil\",\"protocol\":\"freedom\",\"settings\":{\"x\":\"
203.0.113.22 r4.example.com\",\"x\":\"evil.example ${pbk} ab12 ${enc}
203.0.113.23 r5.example.com ${pbk}x ab12 ${enc}
203.0.113.24 r6.example.com ${pbk} 0123456789abcdef0 ${enc}
203.0.113.25 r7.example.com ${pbk} ab12 mlkem.short
203.0.113.26 r8.example.com ${pbk} ab12 ${enc} own-site aaaa\"evil"
a=$(cc SUBSCRIPTION=false "RELAYS=$good" -- --full phone)
b=$(cc SUBSCRIPTION=false "RELAYS=$bad" -- --full phone)
[ "$a" = "$b" ] || fail "malformed lines: the output changed"
grep -q evil <<<"$b" && fail "malformed lines: an injected value reached the output"
for w in '4: its encryption' '5: its encryption' '6: its site' '7: its public key' '8: its short id' '9: its encryption' '10: its XHTTP path'; do
  grep -qF "relays: line $w is malformed; left out" "$work/err" || fail "malformed lines: line ${w%%:*} not said"
done
out=$(cc SUBSCRIPTION=false "RELAYS=203.0.113.9 c.example.com ${pbk} 01 none kcp=9448,dtls,abcd\"}]},{\"tag\":\"dotdash-evil
203.0.113.10 d.example.com ${pbk} 01 none kcp=09448,dtls,abcd" -- --full phone)
[ "$(grep -c 'kcp= field of' "$work/err")" = 2 ] || fail "a kcp= field with more after its seed, or a port from 0: not said"
grep -qE 'evil|#relay%20[0-9]%20%C2%B7%20kcp' <<<"$out" && fail "a malformed kcp= field still gives an mKCP link"

echo "== an unknown key= in a relays line: said, and ignored"
out=$(cc SUBSCRIPTION=false "RELAYS=$relay cdn_path=cccc3333" -- --full phone)
grep -qF 'relays: line 1: no field is named cdn_path=; ignored' "$work/err" || fail "an unknown key= not said"
[ "$out" = "$(cc SUBSCRIPTION=false "RELAYS=$relay" -- --full phone)" ] || fail "an unknown key= changed the output"

echo "== --check: nothing on a clean list, each bad line by its number, nothing printed but that"
out=$(cc "RELAYS=$relay" "POOLS=p1 phone 203.0.113.7" CDN_HOSTS=cdn1.example.net -- --check)
[ -z "$out" ] && [ ! -s "$work/err" ] || fail "--check: output for clean lists"
out=$(cc "RELAYS=$relay
203.0.113.8 b.example.com ${pbk} ab12 ${enc} cdn=bad_name!" "POOLS=p1 phone ghost.example.net" \
  'CDN_EXTRA=cdn.example.net {"mode": broken}' -- --check)
[ -z "$out" ] || fail "--check: something on stdout"
for w in 'relays: line 2: the cdn= field of 203.0.113.8' 'pools: line 1: ghost.example.net is no device name' \
  'cdn_extra: line 1: Xray refuses the extra for cdn.example.net'; do
  grep -qF "$w" "$work/err" || fail "--check: not said: $w"
done
grep -q '^warning: pools: line 1: ghost' "$work/err" || fail "--check: a pool member that names nothing is not a warning"
grep -q '^relays: line 2: the cdn= field' "$work/err" || fail "--check: a dropped field is marked a warning"
# What the lists health check lets through: a field a newer relay's line may
# carry, a name two relays share, a pool member that names nothing.
out=$(cc "RELAYS=$relay future=1
203.0.113.8 b.example.com ${pbk} ab12 ${enc} name=edge" "POOLS=p1 phone ghost.example.net" -- --check)
[ -s "$work/err" ] && ! grep -qv '^warning: ' "$work/err" || fail "--check: an unknown field, a taken name or a stray pool member is not a warning alone"

echo "== servers naming none: this server alone, and said"
[ "$(cc SUBSCRIPTION=false 'SERVERS= , ' -- --full phone)" = "$out_self" ] || fail "servers naming none: not this server alone"
grep -qF 'servers names no server: this one alone' "$work/err" || fail "servers naming none: not said"

echo "== subscriptions on: the URL alone without --full, one per device"
[ "$(cc SUBSCRIPTION=true -- | grep -cE '^https://s\.example\.com/[0-9a-f]{32}$')" = 3 ] || fail "subscription: not one URL per device"

echo "== the golden: every transport, profile and relays field, pools, cdn_extra, kinds, direct=false, several servers"
gold() { # <case> <env assignments...> -- <client-config arguments...>: the case's exit code, stdout and stderr, appended to $work/golden
  local name=$1 rc=0
  shift
  cc "$@" >"$work/out" || rc=$?
  { printf '=== %s\n--- exit %s\n' "$name" "$rc"; cat "$work/out"; echo "--- stderr"; cat "$work/err"; } >>"$work/golden"
}
: >"$work/golden"
own="own-site aaaa1111bbbb2222"
relays="# relays: every field
203.0.113.1 a.example.com ${pbk} 0123456789abcdef ${enc}
203.0.113.2 r.example.com ${pbk} ab12 ${enc} ${own} kcp=9447,dtls,00112233445566778899aabbccddeeff hy2=8443 cdn=cdn-r1.example.net,cdn-r2.example.net cdnpath=cccc3333dddd4444eeee5555 origin=o1.example.org,o2.example.org/e/tok/s/ name=edge

203.0.113.3 q.example.com ${pbk} 01 none kcp=9448,wireguard,abcdef,quic
203.0.113.4 p.example.com ${pbk} 02 ${enc} own-site 0123abcd cdn=cdn-p.example.net kcp=9449,none,ff00
203.0.113.5 c.example.com ${pbk} 03 ${enc} own-site 0a0b cdn=cdn-c.example.net cdn-only name=hidden
203.0.113.6 x.example.com ${pbk} 04 ${enc} own-site 0c0d kcp=9450,srtp,aa hy2=9443 off=reality,xhttp
203.0.113.7 y.example.com ${pbk} 05 ${enc} own-site 0e0f kcp=9451,utp,bb hy2=9444 off=mkcp,hysteria2 split
203.0.113.8 z.example.com ${pbk} 06 ${enc} off=reality split
203.0.113.9 s.example.com ${pbk} 07 ${enc} own-site 1a1b cdn=cdn-s.example.net cdnpath=abab hy2=443 kcp=9452,wechat,cc standby name=spare
2001:db8::9 t.example.com ${pbk} 08 ${enc} standby"
# Each said, and left out or cut down to what holds.
bad="203.0.113.10 d.example.com ${pbk} 09 ${enc} name=twin
203.0.113.11 e.example.com ${pbk} 0a ${enc} name=twin
203.0.113.12 f.example.com ${pbk} 0b ${enc} kcp=9453,dtls name=bad/name
203.0.113.13 g.example.com ${pbk} 0c ${enc} hy2=99999
203.0.113.14 h.example.com ${pbk} 0d ${enc} hy2=8443
203.0.113.15 i.example.com ${pbk} 0e ${enc} cdn=bad_name!
203.0.113.16 j.example.com ${pbk} 0f ${enc} cdn=cdn-j.example.net
203.0.113.17 k.example.com ${pbk} 10 ${enc} own-site 2a2b cdn=cdn-k.example.net cdnpath=not/hex
203.0.113.18 l.example.com ${pbk} 11 ${enc} own-site 3a3b origin=o3.example.org
203.0.113.19 m.example.com ${pbk} 12 ${enc} own-site 4a4b cdnpath=5a5b origin=,bad
203.0.113.20 n.example.com ${pbk} 13 ${enc} off=Bad!
203.0.113.21 o.example.com ${pbk} 14 ${enc} off=reality,foo
203.0.113.22 p2.example.com ${pbk} 15 ${enc} cdn-only
203.0.113.23 q2.example.com ${pbk} 16 ${enc} cdn_path=abc
203.0.113.24 bad\"site ${pbk} 17 ${enc}
203.0.113.25 short.example.com"
pools="p1 phone 203.0.113.2 cdn-r1.example.net o2.example.org scdn1.example.net
p2 laptop 203.0.113.3 cdn-r2.example.net # a comment
# a pool of nothing
p3 nobody.example.net"
extra='scdn2.example.net {"uplinkHTTPMethod": "GET", "uplinkChunkSize": 2048}
o2.example.org {
  "mode": "packet-up",
  "xPaddingKey": "_t"
}
cdn-r2.example.net {"mode": broken}
bad"host {"a": 1}
cdn-p.example.net notjson'
fleet=("RELAYS=$relays" "POOLS=$pools" "CDN_HOSTS=scdn1.example.net, scdn2.example.net,bad_x" "CDN_EXTRA=$extra")
profiles=(XHTTP_REALITY_PORT=8443 KCP_PORT=8447 HYSTERIA2_PORT=443 XDNS_DOMAIN=t)
gold "plain" SUBSCRIPTION=false -- --full phone
gold "--local-auth" SUBSCRIPTION=false -- --local-auth phone
gold "subscriptions, the URLs" SUBSCRIPTION=true --
gold "subscriptions, --full, entry_port 8443" SUBSCRIPTION=true ENTRY_PORT=8443 -- --full phone
gold "every profile" "${profiles[@]}" XDNS_TTI=100 "XDNS_RESOLVERS=udp://1.1.1.1:53,https://dns.example/dns-query" -- --full phone
gold "mkcp quic, header none" KCP_PORT=8447 KCP_HEADER=none KCP_OPEN=quic -- --full laptop
gold "several servers, hello split" "SERVERS=self, s2.example.com" HELLO_SPLIT=true \
  XHTTP_REALITY_PORT=8443 KCP_PORT=8447 KCP_OPEN=quic HYSTERIA2_PORT=8448 -- --full phone
gold "the fleet, every device" SUBSCRIPTION=true KCP_PORT=8447 HYSTERIA2_PORT=443 "${fleet[@]}" -- --full
gold "the fleet, several servers and every profile, by uuid" SUBSCRIPTION=true "SERVERS=self,s2.example.com" \
  "${profiles[@]}" "${fleet[@]}" -- --full 2c3d4e5f-6071-4829-9bac-1d2e3f4a5b6c
gold "the fleet, the URLs" SUBSCRIPTION=true "${fleet[@]}" --
gold "the fleet, direct=false" SUBSCRIPTION=true DIRECT=false "${profiles[@]}" "${fleet[@]}" -- --full phone
gold "relays lines said, then left out or cut down" "RELAYS=$bad" -- --full phone
gold "direct=false, nothing else" SUBSCRIPTION=true DIRECT=false -- --full phone
gold "direct=false, no subscriptions" SUBSCRIPTION=false DIRECT=false "CDN_HOSTS=scdn1.example.net" -- --full
gold "the DNS tunnel with a standby relay" XDNS_DOMAIN=tun.example.org \
  "RELAYS=203.0.113.1 a.example.com ${pbk} 01 ${enc}
2001:db8::9 t.example.com ${pbk} 08 ${enc} standby" -- --full phone
gold "servers naming none" "SERVERS= , " -- --full phone
gold "no such client" -- --full nobody
gold "xdns_tti out of range" XDNS_DOMAIN=t XDNS_TTI=5 -- --full phone
gold "a bad xdns_resolvers" XDNS_DOMAIN=t XDNS_RESOLVERS=dns.example -- --full phone
gold "entry_port not a port" ENTRY_PORT=x -- --full phone
gold "--check, the fleet" SUBSCRIPTION=true "${profiles[@]}" "${fleet[@]}" -- --check
gold "--check, every line said" "RELAYS=$bad" -- --check
# off=cdn:<name>: that CDN's links and outbounds go, under every path of the
# name, the rest keep their numbers, a pool may still name it, and a cdn-only
# relay left with none goes, unsaid.
gold "off= names CDNs" "POOLS=p1 phone a.example.net d1.example.net" "RELAYS=203.0.113.2 r.example.com ${pbk} ab12 ${enc} ${own} kcp=9447,dtls,aa cdn=a.example.net,b.example.net cdnpath=cccc3333dddd4444eeee5555 origin=o.example.org,o.example.org/e/x/ off=cdn:a.example.net,cdn:o.example.org,mkcp
203.0.113.3 c.example.com ${pbk} 01 ${enc} own-site 0a0b cdn=c.example.net cdn-only off=cdn:c.example.net
203.0.113.4 d.example.com ${pbk} 02 ${enc} own-site 0c0d cdn=d1.example.net,d2.example.net cdn-only off=cdn:d1.example.net
203.0.113.5 e.example.com ${pbk} 03 ${enc} off=reality,cdn:a..b
203.0.113.6 f.example.com ${pbk} 04 ${enc} off=cdn:Bad_host!" -- --full phone
golden=.github/tests/client-config.golden
if [ "${UPDATE_GOLDEN:-}" = 1 ]; then
  cp "$work/golden" "$golden"
  echo "client-config: the golden written to $golden"
elif ! diff -u "$golden" "$work/golden" >"$work/golden.diff"; then
  head -n 200 "$work/golden.diff" >&2
  fail "the golden: the output changed (above); if meant, run again with UPDATE_GOLDEN=1 and commit its diff"
fi

echo "== the client smoke's stand-in: this REALITY link and these outbounds, its values left out"
out=$(cc SUBSCRIPTION=false DOMAIN=www.gstatic.com ENTRY_PORT=9443 -- --full phone)
obs=$(printf '%s\n' "$out" | config | jq -c '[.outbounds[] | select(.tag == "dotdash-1-reality" or .protocol == "dns")]')
blank=$(jq -r '.[0] | "s/\(.settings.id)/{id}/g; s/\(.settings.encryption)/{enc}/g; s/\(.streamSettings.realitySettings.password)/{pbk}/g"' <<<"$obs")
got=$(printf '%s\n%s\n' "$(printf '%s\n' "$out" | links | grep '#server%20%C2%B7%20reality$')" "$obs" | sed "$blank
  s/@www\.gstatic\.com:/@{host}:/; s/\"address\":\"www\.gstatic\.com\"/\"address\":\"{host}\"/; s/sid=ab12&/sid={sid}\&/; s/\"shortId\":\"ab12\"/\"shortId\":\"{sid}\"/")
[ "$got" = "$(cat .github/client-smoke.d/pre-apply/server.txt)" ] ||
  fail "the client smoke's stand-in is not client-config's; .github/client-smoke.d/pre-apply/server.txt should read:
$got"

[ "$failed" = 0 ] && echo "client-config: all cases pass"
exit "$failed"
