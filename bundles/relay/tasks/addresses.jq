# The device-addresses profile's counts (facts.sh), from Xray's
# `api statsonlineiplist -all`: how many distinct addresses each device is
# connected from right now, by name, at $at. A count, never an address. An
# IPv6 address counts by its /64, the network one line hands out, inside which
# a phone's own addresses change; Xray prints each in its shortest form, so
# its first four groups, with :: spelled out, are its /64. A name that would
# need escaping in JSON is left out, as facts.sh's traffic leaves it out, and
# with it the gateway's checkers (#check@<group>) and unnamed devices.
def net64:
  if test(":") and (test("[.]") | not) then
    split("::") as $p
    | ($p[0] | if . == "" then [] else split(":") end) as $l
    | ($p[1] // "" | if . == "" then [] else split(":") end) as $r
    | ($l + [range(8 - ($l | length) - ($r | length)) | "0"] + $r)[:4] | join(":")
  else . end;
{at: $at, devices: ([.users[]? | select(.email | test("^[A-Za-z0-9._@+-]+$"))
  | {key: .email, value: ([.ips[]?.ip | net64] | unique | length)}] | from_entries)}
