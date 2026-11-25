#!/usr/bin/env bash
# client-config.sh, the server's task, run as the task runs it (the Caddy
# image's shell, the Xray image's binaries, the secrets as files) against a
# matrix of parameters, its links and Xray config checked with jq: what the
# rig's smoke would catch only after an install, in seconds and without one.
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
docker run --rm --entrypoint /usr/local/bin/xray "$xray" x25519 | sed -n 's/^Private[^:]*: *//p' >"$work/secrets/reality_key"
head -c 64 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$work/secrets/vless_seed"
printf ab12 >"$work/secrets/reality_short_id"
printf 'aaaa1111bbbb2222' >"$work/secrets/xhttp_path"
printf seedkcp >"$work/secrets/kcp_seed"
printf subkey >"$work/secrets/subscription_key"
printf '0593b52c-b345-41cb-96b8-134724f6ca65 phone\n1b2c3d4e-5f60-4718-8a9b-0c1d2e3f4a5b laptop\n2c3d4e5f-6071-4829-9bac-1d2e3f4a5b6c desk desktop\n' >"$work/secrets/vless_clients"
chmod 644 "$work"/secrets/*

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

echo "== --local-auth: one inbound with a password, the same each run, the rest unchanged"
a=$(cc SUBSCRIPTION=false -- --local-auth phone | config)
b=$(cc SUBSCRIPTION=false -- --local-auth phone | config)
jq -e '.inbounds | length == 1 and .[0].settings.auth == "password" and (.[0].settings.accounts[0].pass | length) == 32' \
  <<<"$a" >/dev/null || fail "--local-auth: not one SOCKS inbound with a 32-character password"
[ "$a" = "$b" ] || fail "--local-auth: another password on another run"
[ "$(jq -S 'del(.inbounds)' <<<"$a")" = "$(jq -S 'del(.inbounds)' <<<"$plain")" ] ||
  fail "--local-auth: the config changed beyond its inbounds"

relay='203.0.113.7 r.example.com PBK ab12 ENC own-site aaaa1111bbbb2222 cdn=cdn.example.net cdnpath=cccc3333dddd4444 origin=o.example.ru name=edge'
echo "== a relay with a CDN and a door: the CDN's links disguised, the door's plain in 4 KiB"
out=$(cc SUBSCRIPTION=false "RELAYS=$relay" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-1") | .streamSettings.xhttpSettings |
    .scMaxEachPostBytes == 8192 and .xPaddingObfsMode == true and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "relay: the CDN's outbound is not disguised, 8 KiB, on the CDN path"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-2") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "o.example.ru" and .scMaxEachPostBytes == 4096 and .uplinkChunkSize == 4096 and (.xPaddingObfsMode // false) == false
    and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "relay: the door's outbound is not plain, 4 KiB, on the CDN path, to its name"
printf '%s\n' "$out" | links | grep -q '^vless://[^@]*@o\.example\.ru:443?.*scMaxEachPostBytes%22%3A4096.*#edge%20%C2%B7%20cdn%202$' ||
  fail "relay: no 4 KiB link through the door, named edge · cdn 2"

echo "== a door with two names: a 4 KiB link and outbound through each, numbered after the CDN's"
out=$(cc SUBSCRIPTION=false "RELAYS=${relay/origin=o.example.ru/origin=o.example.ru,alt.example.ru}" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-3") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "alt.example.ru" and .scMaxEachPostBytes == 4096 and .path == "/cccc3333dddd4444"] == [true]' <<<"$cfg" >/dev/null ||
  fail "two door names: the second's outbound is not plain, 4 KiB, on the CDN path, to its name"
for n in '2 o\.example\.ru' '3 alt\.example\.ru'; do
  printf '%s\n' "$out" | links | grep -q "^vless://[^@]*@${n#* }:443?.*scMaxEachPostBytes%22%3A4096.*#edge%20%C2%B7%20cdn%20${n%% *}\$" ||
    fail "two door names: no 4 KiB link through ${n#* }, named edge · cdn ${n%% *}"
done
out=$(cc SUBSCRIPTION=false "RELAYS=${relay/origin=o.example.ru/origin=o.example.ru,,x}" -- --full phone)
grep -q "origin= field of 203.0.113.7 is not <host>\[/<path>\]" "$work/err" || fail "a bad door list: not said"

echo "== a door name with a gateway's path, and cdn_extra: links and outbounds take both; one Xray refuses is said, and left out"
extra='alt.example.ru {
  "mode": "packet-up",
  "uplinkHTTPMethod": "GET",
  "xPaddingKey": "_t", "xPaddingObfsMode": true
}
# a comment
scdn.example.net {"uplinkHTTPMethod": "GET", "uplinkChunkSize": 2048}
cdn.example.net {"mode": broken}'
out=$(cc SUBSCRIPTION=false CDN_HOSTS=scdn.example.net "RELAYS=${relay/origin=o.example.ru/origin=o.example.ru,alt.example.ru/e/tok/s/}" \
  "CDN_EXTRA=$extra" "POOLS=p1 phone alt.example.ru" -- --full phone)
cfg=$(printf '%s\n' "$out" | config)
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-3") | .settings.address as $a | .streamSettings.xhttpSettings |
    $a == "alt.example.ru" and .host == "alt.example.ru" and .path == "/e/tok/s/" and .extra.xPaddingKey == "_t"
    and .extra.xPaddingObfsMode == true and .scMaxEachPostBytes == null] == [true]' <<<"$cfg" >/dev/null ||
  fail "gateway path: the outbound is not to alt.example.ru on /e/tok/s/ with its extra alone"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-1") | .streamSettings.xhttpSettings.extra.uplinkChunkSize] == [2048]' <<<"$cfg" >/dev/null ||
  fail "cdn_extra: the server's CDN outbound does not carry its extra"
jq -e '[.outbounds[] | select(.tag == "dotdash-cdn-relay-1-1") | .streamSettings.xhttpSettings |
    .xPaddingObfsMode == true and .scMaxEachPostBytes == 8192 and .extra == null] == [true]' <<<"$cfg" >/dev/null ||
  fail "cdn_extra: a refused extra was not left out, the CDN's outbound not disguised as before"
grep -q "Xray refuses the extra for cdn.example.net" "$work/err" || fail "cdn_extra: a refused extra not said"
grep -q "pools: alt.example.ru" "$work/err" && fail "pools: a door name with a path not taken as a member"
link=$(printf '%s\n' "$out" | links | grep '^vless://[^@]*@alt\.example\.ru:443?.*sni=alt\.example\.ru&host=alt\.example\.ru&.*path=%2Fe%2Ftok%2Fs%2F&.*#edge%20%C2%B7%20cdn%203$') ||
  fail "gateway path: no link through alt.example.ru on its path, named edge · cdn 3"
e=$(printf '%s' "$link" | sed -n 's/.*[?&]extra=\([^&#]*\).*/\1/p')
printf '%b' "${e//%/\\x}" | jq -e '.xPaddingKey == "_t" and .uplinkHTTPMethod == "GET"' >/dev/null ||
  fail "gateway path: the link's extra is not cdn_extra's, percent-encoded"

echo "== a desktop: no CDN link or outbound, the server's or a relay's, and nothing through a cdn-only relay"
only='203.0.113.9 q.example.com PBK ab12 ENC own-site aaaa1111bbbb2222 cdn=cdn2.example.net cdn-only name=hidden'
envs=(SUBSCRIPTION=false CDN_HOSTS=scdn.example.net "RELAYS=$relay
$only")
out=$(cc "${envs[@]}" -- --full desk)
[ -z "$(printf '%s\n' "$out" | links | grep -E '@(scdn|cdn|cdn2|o)\.example\.(net|ru):|@203\.0\.113\.9:')" ] ||
  fail "desktop: a CDN link, or one through the cdn-only relay"
printf '%s\n' "$out" | links | grep -q '^vless://[^@]*@203\.0\.113\.7:443?.*security=reality.*#edge%20%C2%B7%20reality$' ||
  fail "desktop: no REALITY link through the relay"
printf '%s\n' "$out" | config | jq -e '[.outbounds[].tag | select(test("cdn"))] == []' >/dev/null ||
  fail "desktop: a CDN outbound in the config"
out=$(cc "${envs[@]}" -- --full phone)
[ "$(printf '%s\n' "$out" | links | grep -cE '@(scdn|cdn|cdn2|o)\.example\.(net|ru):')" = 4 ] ||
  fail "a device of no kind: not every CDN link"

echo "== origin= without cdnpath=: said, and no link through it"
out=$(cc SUBSCRIPTION=false "RELAYS=203.0.113.7 r.example.com PBK ab12 ENC own-site aaaa1111bbbb2222 origin=o.example.ru" -- --full phone)
grep -q "names origin= but no cdnpath=" "$work/err" || fail "origin without cdnpath: not said"
printf '%s\n' "$out" | links | grep -q '@o\.example\.ru:' && fail "origin without cdnpath: a link through it anyway"

echo "== pools: a device in a pool gets its pool's relay and those in none"
two="203.0.113.7 a.example.com PBK ab12 ENC
203.0.113.8 b.example.com PBK ab12 ENC
203.0.113.9 c.example.com PBK ab12 ENC"
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
cfg=$(cc SUBSCRIPTION=false "RELAYS=203.0.113.7 a.example.com PBK ab12 ENC
203.0.113.8 b.example.com PBK ab12 ENC standby" -- --full phone | config)
jq -e '.outbounds[0].tag | startswith("standby")' <<<"$cfg" >/dev/null || fail "standby: not the first outbound"
jq -e '[.outbounds[].tag | select(startswith("dotdash-relay"))] | length >= 1' <<<"$cfg" >/dev/null ||
  fail "standby: the normal relay's outbound is missing"

echo "== the server's CDN hosts: an 8 KiB GET link and outbound each"
out=$(cc SUBSCRIPTION=false CDN_HOSTS=cdn1.example.net,cdn2.example.net -- --full phone)
[ "$(printf '%s\n' "$out" | config | jq '[.outbounds[] | select(.tag | startswith("dotdash-cdn-")) | .streamSettings.xhttpSettings |
  select(.scMaxEachPostBytes == 8192 and .uplinkHTTPMethod == "GET")] | length')" = 2 ] ||
  fail "cdn_hosts: not two 8 KiB GET outbounds"

echo "== subscriptions on: the URL alone without --full, one per device"
[ "$(cc SUBSCRIPTION=true -- | grep -cE '^https://s\.example\.com/[0-9a-f]{32}$')" = 3 ] || fail "subscription: not one URL per device"

[ "$failed" = 0 ] && echo "client-config: all cases pass"
exit "$failed"
