#!/bin/sh
# Checks each CDN in front of this server (cdn_hosts) and of its relays (the
# cdn= and origin= names on their lines), from outside, through Xray's probe
# inbound, so through the upstreams, as devices' traffic leaves. Changes
# nothing; exits 1 when a CDN serves subscriptions or its data path does not
# reach Xray.
#
# Subscriptions: whether a CDN in front of a site (cdn_hosts, cdn=) is refused
# them, as it should be. It fetches a decoy through each: a file the
# subscription service writes beside the devices', with no links in it, named
# from the key so no one else can ask for it, and holding the rest of that
# hash. A request a CDN marks as passed on gets the site, as any other path
# does: its 404, or the answer of an app behind it (cover), which may be a 200
# but never that hash. A CDN that marks nothing gets the decoy.
#
# The data path: a request with no session on the path the name's links take
# (the CDN path, the relay's XHTTP path before cdnpath=, a door's or a
# gateway's), which Xray's XHTTP inbound turns down with a 400 (Xray 26.11),
# where the site answers a path that leads nowhere with its 404. So a 400 says
# the CDN reaches the origin and the path reaches Xray; a 404, that the path
# is stale or a door (origin=) refused the CDN's address; a 5xx or no answer,
# that the CDN does not reach its origin.
set -u
probe() { # <expect> <url>: its answer in why, the probe's own line past the proxy, never the URL (it holds a secret path or the decoy's name); 0 on a 2xx that matches
  out=$(XRAY_HEALTHCHECK_EXPECT="$1" XRAY_HEALTHCHECK_URL="$2" /opt/xray/xray-entrypoint healthcheck 2>&1)
  rc=$?
  why=$(printf '%s\n' "$out" | sed -n 's/^healthcheck: GET .* through [^ ]*: //p' | head -n 1 | sed 's/^[A-Za-z]* "[^"]*": //')
  return "$rc"
}
export XRAY_HEALTHCHECK_PROXY=http://127.0.0.1:10809 XRAY_HEALTHCHECK_TIMEOUT=15s

# Each name once, as "<cdn|origin> <name> <path>": the path its links take,
# with a trailing slash where a session follows it. The relays lines are as
# the lists health check let them through.
names=$({
  cp=
  [ "${CDN_HOSTS:-none}" = none ] || cp=$(cat /run/secrets/cdn_xhttp_path)
  for h in $(printf '%s' "${CDN_HOSTS:-none}" | tr ',' ' '); do [ "$h" = none ] || echo "cdn $h $cp"; done
  # A relay/1 line names its own site's path by xhttp=, a line of before by
  # own-site <path>.
  printf '%s\n' "${RELAYS:-}" | awk '!/^[ \t]*(#|$)/ {
    n = 0; c = ""; cp = ""; o = ""; x = ""
    for (i = 1; i <= NF; i++)
      if ($i ~ /^cdn=/) c = substr($i, 5); else if ($i ~ /^cdnpath=/) cp = substr($i, 9)
      else if ($i ~ /^origin=/) o = substr($i, 8); else if ($i ~ /^xhttp=/) x = substr($i, 7)
      else if ($i !~ /=/ && $i != "cdn-only" && $i != "split" && $i != "standby") f[++n] = $i
    p = ($1 == "relay/1") ? (x != "" ? x "/" : "") : (n >= 7 && f[6] == "own-site") ? f[7] "/" : ""
    k = split(c, a, ","); for (j = 1; j <= k; j++) print "cdn", a[j], (cp != "" ? cp : p)
    k = split(o, a, ","); for (j = 1; j <= k; j++) { h = a[j]; sub(/\/.*/, "", h); q = substr(a[j], length(h) + 2)
      if (q == "") q = cp; if (q != "") { sub(/\/*$/, "/", q); print "origin", h, q } } }'
} | awk 'NF == 3 && !seen[$2 " " $3]++')
[ -n "$names" ] || { echo "no CDN in front of this server or its relays"; exit 0; }

# The decoy's name, and its own contents: a 2xx without them is the site's.
sum=
if [ "${SUBSCRIPTION:-false}" = true ]; then
  sum=$(printf '%s:cdn-check' "$(cat /run/secrets/subscription_key)" | sha256sum)
else
  echo "subscriptions are off: none for a CDN to be refused"
fi
# Each name's subscriptions once, then each path of its.
printf '%s\n' "$names" | { bad=0 asked=; while read -r kind h path; do
  if [ "$kind" != cdn ] || [ -z "$sum" ]; then :
  elif case " $asked " in *" $h "*) true ;; *) asked="$asked $h"; false ;; esac then :
  elif probe "$(echo "$sum" | cut -c33-64)" "https://$h/$(echo "$sum" | cut -c1-32)"; then
    echo "$h: SERVES SUBSCRIPTIONS: it passes requests on without saying so, so a device's links fetched through it pass through its hands"
    bad=1
  else
    case $why in
    '404 '*) echo "$h: refused subscriptions, as it should" ;;
    2[0-9][0-9]' '*) echo "$h: refused subscriptions, as it should: the site answered, not with the decoy" ;;
    *) echo "$h: subscriptions: answered ${why:-nothing}, not the site's 404 (the data path below tells more)" ;;
    esac
  fi
  url="https://$h/$path"
  case $path in */) url=$url$(cat /proc/sys/kernel/random/uuid) ;; esac
  if probe '.*' "$url"; then
    echo "$h: the data path: answered with a 2xx, not as Xray answers: the CDN serves its own page, or another origin"
    bad=1
    continue
  fi
  case $why in
  '400 '*) echo "$h: the data path reaches Xray (it turned down a request with no session, as it does)"; continue ;;
  '404 '*) echo "$h: the data path ends at the site's 404, not Xray: the line's path is stale, or a door (origin=) refused the CDN's address (http_origin_from)" ;;
  5[0-9][0-9]' '*) echo "$h: the data path: $why: the CDN does not reach its origin, or what is behind the origin's site is down" ;;
  [0-9][0-9][0-9]' '*) echo "$h: the data path: $why, not as Xray answers: the CDN refused it, or serves another origin" ;;
  *imeout* | *deadline*) echo "$h: the data path: no answer within 15 s: the CDN does not reach its origin, or the upstreams are down" ;;
  *tls* | *x509* | *certificate*) echo "$h: the data path: TLS to the CDN failed: $why" ;;
  *) echo "$h: the data path: could not tell: ${why:-no answer}" ;;
  esac
  bad=1
done; exit "$bad"; }
