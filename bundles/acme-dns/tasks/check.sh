#!/bin/sh
# The container's health check: the zone answers over DNS, and the API over
# HTTPS under its certificate (plain HTTP with api_tls=none). The zone's name
# is this container's alias on the project's network.
set -eu
nslookup -type=soa "$ZONE" 127.0.0.1 >/dev/null
url=https://$ZONE
[ "$API_TLS" = none ] && url=http://$ZONE:443
wget -q -O /dev/null "$url/health"
