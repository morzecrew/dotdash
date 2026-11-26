# shellcheck shell=bash
# Sourced by the hooks that need a site only the stand-in server
# (pre-apply/10-server.sh) reaches: busybox's httpd on that server's
# loopback, in its network namespace. A canary check that left by the rig's
# own network instead of through dotdash finds nothing there, so a check that
# reads a freeze or a download from these went through the tunnel. The
# server's namespace is a new one each time it starts: a hook starts the sites
# itself, after any restart.
#
#   ${sites}/down             1 MB, whole
#   ${sites}/cgi-bin/cut      20 KB of a 64 KB body, then closed: a freeze, as the canary meets one
#   ${sites}/cgi-bin/silent   takes an upload and never answers
sites=http://127.0.0.1:9080

start_sites() {
  local busybox
  busybox=$(sudo docker image ls --digests --format '{{.Repository}}@{{.Digest}}' busybox | sed -n 1p)
  [ -n "${busybox}" ] || die "the bundle's pinned busybox image is not in the rig"
  sudo docker rm -f canary-rig-sites >/dev/null 2>&1 || true
  sudo docker run -d --name canary-rig-sites --network container:canary-rig-server "${busybox}" sh -c '
    mkdir -p /www/cgi-bin && head -c 1000000 /dev/zero >/www/down
    printf "#!/bin/sh\nprintf \"Content-Length: 65536\\r\\n\\r\\n\"\nhead -c 20000 /dev/zero\n" >/www/cgi-bin/cut
    printf "#!/bin/sh\nsleep 60\n" >/www/cgi-bin/silent
    chmod +x /www/cgi-bin/*
    exec httpd -f -p 127.0.0.1:9080 -h /www' >/dev/null
  for _ in $(seq 20); do
    sudo docker exec canary-rig-sites wget -q -O /dev/null "${sites}/down" 2>/dev/null && return 0
    sleep 0.5
  done
  die "the stand-in sites do not answer"
}
