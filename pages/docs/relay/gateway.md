# One relay, several server groups

Every relay is a gateway: it carries each device on to that device's own
server group, and to no other. A relay with one line in `servers` and one
with five run the same way. Groups are unrelated networks of servers, each
with its own keys, devices and exit: `a` and `b` below.

## How a device finds its group

- **Its id.** Each group's servers serve the relay a list of their devices,
  which the relay fetches through its own tunnel to that group every
  minute, at an internal name only relays may ask for. The relay names each
  device `<device>@<group>`, and sends it to that group's servers alone.
- **Its subscription.** A device keeps its URL, `https://<relay>/<token>`.
  The relay's site routes it by the token's first 12 hex characters, which
  the device's group lists with each device, and the group's server serves
  it. The relay never holds a whole token: a seized relay can fetch only the
  subscriptions devices ask it for, as before.
- **No restart.** A device added or deleted on its server reaches the relay
  within a minute, through Xray's API. One exception: a device deleted while
  it is connected restarts the relay's Xray, which alone cuts a connection
  already open. Every device's connections then drop, and each device's first
  try after it fails once.

## Isolation

The relay's routing comes from its image, not a template, and three of its
rules fail closed:

- the default way out is a blackhole;
- a group whose servers are all down, or not reached yet after a start,
  falls back to its own first server, never to another group's;
- the last rule blocks whatever no other rule took.

So with `b`'s servers down, `b`'s devices and subscriptions get nothing,
and never reach `a`'s servers or exit. A device can't ask any server for its
internal names through the relay either.

An id that two groups list, which Xray would take for one device, is dropped
from both, as is a subscription prefix two groups share: that device
fetches from its server or another relay. `servers` names what was dropped.

## Health per group

morzer's health check says only that the relay's own machinery works: Xray
runs on the `servers` and `via` it was given, and its agent reached Xray in
the last two minutes. An idle relay, or one whose groups are all down, is
healthy, and a `servers` line a server doesn't take yet rolls nothing back.

Each group has a state of its own:

| State | When | Its devices get |
| --- | --- | --- |
| `starting` | since the relay started, before its first round | nothing |
| `live` | one of its servers serves the relay its list | through the relay |
| `down` | none answers | nothing, kept from its last list |
| `refused` | a server answers that it has no list for this relay | nothing: its list is dropped |

`refused` means this relay's line is not in that server's `relays`, or the
relay's `servers` line for the group is out of date. The state is in the
`servers` task, in the facts under `groups`, in the log
(`gateway: group b down: …`), and under the `metrics` profile in
`dotdash_group_live{group}`, `dotdash_group_devices{group}` and
`dotdash_group_list_age_seconds{group}`. morzer's `notify` fires only on a
failed health check, so alert on `dotdash_group_live == 0` for a group.

A canary is a device of one group: its verdict covers the relay's entry from
the device's network and that one group behind it. A canary that passes
while `servers` says `b down` means the entry is fine and `b` is down.

## Through another relay

`via` works per group with no special case. Relay X lists relay Y's line in
its `via` secret; for each group, X reaches Y with its own id there, and Y
lets it in because that group's list for Y holds X's id. A group Y doesn't
serve is refused at Y, and X shows it `down`.

## What a seized relay gives away

Every group's `server/1` line, each a way into that group's servers and exit;
the relay's keys; and, while it runs, every group's device ids, which it
holds in memory alone. The `servers` secret is on disk, encrypted to the
machine's own identity on the same disk. Delete the relay's line from each
server's `relays` to cut it off; a new `relay_seed` on a group cuts off every
relay of that group.

## Moving from 0.18

A relay at 0.19 needs servers at 0.19: update the servers first. A server at
0.19 still reads the relay lines of 0.18 for one release, so its update keeps
every link. Each relay then idles from its update until its `servers` line
is in, a few minutes. Rehearse it on a spare first. For server S and relays
R1…Rn:

1. **Before.** On S, keep the old lines for the way back, and pick each
   relay's name and S's name. Leave each relay's old `<uuid> <name>` line in
   S's `vless_clients` until the end.

    ```sh
    sudo morzer config get relays > ~/relays.0.18
    ```

2. **S first.** Its devices see no change: the old relays still come in by
   their lines in `vless_clients`.

    ```sh
    sudo morzer self-update                       # if the release notes ask for a newer morzer
    sudo morzer update --stage
    sudo morzer update --to 0.19.0 --set name=s
    sudo morzer task run client-config --output -- --check
    ```

3. **Each relay, one at a time.** Devices use the others meanwhile.

    ```sh
    # on Ri: its dotdash_* values and vless_clients are dropped, and it idles
    sudo morzer update --stage
    sudo morzer update --to 0.19.0 --set name=ri
    sudo morzer task run relay-entry --output -- <its domain, or its IP>
    # on S: replace Ri's old line with that relay/1 line. The same host,
    # keys and transports, so devices' links don't change
    sudo EDITOR=nano morzer config edit relays
    sudo morzer task run relay-config --output -- ri
    # on Ri
    sudo EDITOR=nano morzer secret edit servers   # the server/1 line
    sudo morzer task run servers --output         # within a minute: s live
    sudo morzer task run entry-check --output
    ```

    A relay with `via`: move the relays it goes through first, then give it
    `sudo EDITOR=nano morzer secret edit via` with each one's `relay/1` line,
    before `servers`. The `via` parameter's old lines are dropped with the
    update (`config list` marks the value stale; `config unset via` clears
    it). `dotdash_link` is now `server_link`. Under `own-site`, a device that
    refreshes its subscription through the relay during the gap gets the
    site; its app keeps its old links, and the next refresh works.

4. **The end.** On S, once every relay's line in `relays` is a `relay/1`
   line, delete each relay's old line from `vless_clients`:
   `sudo EDITOR=nano morzer secret edit vless_clients`.

**The way back**, relays first: a server back at 0.18 can't read `relay/1`
lines. A relay's `morzer rollback` is refused, as 0.19 drops values 0.18
requires: restore its pre-update backup instead, then put its old line back
in S's `relays` from `~/relays.0.18`.

```sh
sudo morzer restore --backup <the pre-update one> --force --confirm <installation-id>
```

S goes back with `sudo morzer rollback` once no `relay/1` line is left in
its `relays`.

What else changes: health no longer says whether the servers answer (watch
`dotdash_group_live` instead), the facts carry `groups` in place of
`clients`, device traffic is counted per `<device>@<group>`, and the
manager drives a 0.19 relay only from its release with server groups.
