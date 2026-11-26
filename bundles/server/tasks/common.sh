# shellcheck shell=sh
# Sourced by client-config.sh, canary-config.sh and facts.sh: what they share.
: "${DOMAIN:?}" "${HTTPS_PORT:?}"
# The port others dial: entry_port, when a proxy on this machine passes the
# domain through to https_port.
case ${ENTRY_PORT:-none} in none) ;; '' | *[!0-9]*) echo "entry_port is not a port: ${ENTRY_PORT}" >&2; exit 1 ;; *) HTTPS_PORT=$ENTRY_PORT ;; esac

# warn <message>: on stderr, for what costs devices nothing: a field this
# release doesn't know, a name taken twice, a pool member that names nothing.
# Under client-config --check, marked "warning: ", which the lists health
# check lets through, where a line or field devices would lose fails it.
warn() { if [ "${check:-false}" = true ]; then echo "warning: $*" >&2; else echo "$*" >&2; fi; }

hosts() { # <parameter> <list>: the list's host names, one per line, "none" aside; any other entry is said and left out
  printf '%s\n' "$2" | tr ',' '\n' | awk -v p="$1" '{ gsub(/^ +| +$/, "") } $0 == "" || $0 == "none" { next }
    /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*$/ { print; next } { print p ": " $0 " is not a host name; left out" > "/dev/stderr" }'
}

# The servers carrying these clients with the same secrets, in order (the
# servers parameter), one per line; self is this one. A list naming none, such
# as " , ", is this one alone, as an empty one is.
server_list() {
  hosts servers "${SERVERS:-self}" | sed "s/^self\$/${DOMAIN}/" | grep . ||
    { warn "servers names no server: this one alone"; echo "$DOMAIN"; }
}

client_id() { # <name>: the id of the client of that name in vless_clients; else it says so and exits
  while read -r line_id name _ || [ -n "${line_id:-}" ]; do
    case $line_id in '' | '#'*) continue ;; esac
    [ "$1" != "${name:-}" ] || { echo "$line_id"; return 0; }
  done </run/secrets/vless_clients
  echo "no client named '$1' in vless_clients" >&2
  exit 1
}
