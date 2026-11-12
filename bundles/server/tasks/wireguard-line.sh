#!/bin/sh
# Prints the upstreams line for a WireGuard exit from its wg-quick client
# config ($1, a task input), as a wireguard:// share link the gate's image
# reads back into the same settings ($upstreams). One [Peer]: a line dials one
# endpoint. The output holds the private key, so it is a credential.
set -eu
conf=${1:?give the wg-quick file: task run wireguard-line --input conf=<file>}
awk '
  function enc(s) { gsub(/%/, "%25", s); gsub(/\+/, "%2B", s); gsub(/\//, "%2F", s); gsub(/=/, "%3D", s); gsub(/,/, "%2C", s); return s }
  function list(s) { gsub(/[ \t]+/, "", s); return s }
  { sub(/#.*/, ""); sub(/\r$/, "") }
  /^[ \t]*$/ { next }
  /^[ \t]*\[/ {
    sec = tolower($0); gsub(/[][ \t]/, "", sec)
    if (sec == "peer") peers++
    next
  }
  {
    k = $0; sub(/=.*/, "", k); gsub(/[ \t]/, "", k); k = tolower(k)
    v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v)
    if (sec == "interface") {
      if (k == "privatekey") key = v
      else if (k == "address") addr = addr (addr == "" ? "" : ",") list(v)
      else if (k == "mtu") mtu = v
    } else if (sec == "peer") {
      if (k == "publickey") pub = v
      else if (k == "presharedkey") psk = v
      else if (k == "endpoint") ep = v
      else if (k == "allowedips") ips = ips (ips == "" ? "" : ",") list(v)
      else if (k == "persistentkeepalive" && v != "off") ka = v
    }
  }
  END {
    if (peers != 1) { print "wireguard-line: the file has " (peers + 0) " [Peer] sections; a line dials one, so give a file with one" > "/dev/stderr"; exit 1 }
    if (key == "" || addr == "" || pub == "" || ep == "") { print "wireguard-line: the file lacks one of PrivateKey, Address, PublicKey, Endpoint" > "/dev/stderr"; exit 1 }
    q = "publickey=" enc(pub) "&address=" enc(addr)
    if (mtu != "") q = q "&mtu=" mtu
    if (psk != "") q = q "&presharedkey=" enc(psk)
    if (ips != "") q = q "&allowedips=" enc(ips)
    if (ka != "") q = q "&keepalive=" ka
    print "wireguard://" enc(key) "@" ep "?" q
  }
' "$conf"
