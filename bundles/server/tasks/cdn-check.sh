#!/bin/sh
# Tells whether each CDN in front of this server (cdn_hosts) and of its relays
# (the cdn= hosts on their lines) is refused a subscription, as it should be.
# It fetches a decoy through each: a file the subscription service writes
# beside the devices', with no links in it, named from the key so no one else
# can ask for it. The site answers a request a CDN marks as passed on with its
# 404; a CDN that marks nothing gets the decoy. The fetch leaves through Xray's
# probe inbound, so through the upstreams, as devices' traffic does. Changes
# nothing; exits 1 only when a CDN gets the decoy.
set -u
[ "${SUBSCRIPTION:-false}" = true ] || { echo "subscriptions are off: nothing to refuse"; exit 0; }
decoy=$(printf '%s:cdn-check' "$(cat /run/secrets/subscription_key)" | sha256sum | cut -c1-32)
hosts=$({
  printf '%s\n' "${CDN_HOSTS:-none}" | tr ',' '\n'
  printf '%s\n' "${RELAYS:-}" | grep -v '^ *#' | tr ' ' '\n' | sed -n 's/^cdn=//p' | tr ',' '\n'
} | sed -e 's/^ *//' -e 's/ *$//' -e '/^$/d' -e '/^none$/d' | sort -u)
[ -n "$hosts" ] || { echo "no CDN in front of this server or its relays"; exit 0; }

export XRAY_HEALTHCHECK_PROXY=http://127.0.0.1:10809 XRAY_HEALTHCHECK_TIMEOUT=15s
served=0
for h in $hosts; do
  out=$(XRAY_HEALTHCHECK_URL="https://$h/$decoy" /opt/xray/xray-entrypoint healthcheck 2>&1)
  rc=$?
  # The probe's own line, "GET <url> through <proxy>: <status or error>";
  # only what follows the proxy, so the decoy's name is never printed.
  why=$(printf '%s\n' "$out" | sed -n 's/^healthcheck: GET .* through [^ ]*: //p' | head -n 1)
  if [ "$rc" = 0 ]; then
    echo "$h: SERVES SUBSCRIPTIONS: it passes requests on without saying so, so a device's links fetched through it pass through its hands"
    served=1
  else
    case $why in
    '404 '*) echo "$h: refused, as it should be" ;;
    [0-9][0-9][0-9]' '*) echo "$h: answered ${why}, not the site's 404: not served, but the CDN may not reach its origin" ;;
    *) echo "$h: could not tell: ${why:-no answer}" ;;
    esac
  fi
done
exit "$served"
