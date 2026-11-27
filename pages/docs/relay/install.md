# Set up a relay

A relay carries devices of one or more server groups. A server group is one
server, or [several sharing keys](../server/several-servers.md), with a
`name`. Two lines pass between them: the relay's line goes into each
server's `relays`, and each server's line for the relay goes into the
relay's `servers`. Nobody copies devices or ids by hand. The relay fetches
each group's devices from its servers every minute.

![Setup: install the relay with a name, relay-entry prints its line, the line into each server's relays, relay-config on each server prints a line for the relay, those lines into the relay's servers, devices get the relay's links](../assets/diagrams/relay-setup.light.svg#only-light)
![Setup: install the relay with a name, relay-entry prints its line, the line into each server's relays, relay-config on each server prints a line for the relay, those lines into the relay's servers, devices get the relay's links](../assets/diagrams/relay-setup.dark.svg#only-dark)

Each server needs a `name` first, the same on every server of a group: 1 to
16 lowercase letters and digits, starting with a letter, such as `a`. Every
device's app may show it, so pick one that says nothing about the server:

```sh
sudo morzer config set name=a   # on each server of the group
```

## 1. Pick the site

Devices send the name of a site, and anyone probing the relay without its
keys meets that site. Two ways:

**A site of the relay's own** (recommended). A domain whose DNS points at the
relay, and the `own-site` profile: the relay serves a site under that name,
with a certificate from Let's Encrypt. To the network the name and the
address agree, as they do for any real site. It needs:

- a domain, `relay.example.net`, with an `A` record for the relay's address.
  Keep relays under a parent of their own, apart from the servers' (a
  different domain, or `*.r.example.net` beside the servers' `*.s.example.net`):
  a relay's name then tells nothing about the servers, and with a
  [wildcard certificate](../server/certificates.md) its own name stays out of
  the certificate logs;
- port 80 open as well as 443, for the certificate;
- in step 2, `--domain relay.example.net --profile own-site` in place of
  `--set site=…`.

Your own pages go in `/srv/dotdash-relay`; without them it serves a plain
bundled page titled with the domain. Better still, put an app behind it
(`cover`), as on a [server](../server/cover-site.md#an-app-instead-of-pages),
on the network `dotdash-relay_edge`.

**A site next to the relay.** No domain needed: the relay borrows the name of
a real site, and probes get that site's own handshake. But that name's DNS
points at the site, not the relay, and an observer that compares the two
can tell. Pick one that is:

- in the relay's own network, the same hosting provider or nearby, not a big
  name served from somewhere else;
- on TLS 1.3 and HTTP/2. `curl` prints `2` for one that is, and fails for one
  without TLS 1.3:

    ```sh
    curl -so /dev/null --tlsv1.3 --http2 -w '%{http_version}\n' https://site.example.net
    ```

## 2. On the relay: install

Install Docker, sops, age and morzer
([`bootstrap.sh`](../index.md#what-every-machine-needs)), and make a
recovery key as for the server:

```sh
morzer secret recipients generate-recovery-key ~/relay-recovery.key   # keep it off the machine
```

Then install it with its site and a `name`: 1 to 24 letters, digits, dots,
dashes or underscores, unique among each group's relays. Devices' links
through it carry the name, `r1 · reality`, so it too should say nothing
about where the relay is hosted. Here with a site of its own:

```sh
sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-relay:stable \
  --recovery-recipient age1… \
  --domain relay.example.net --profile own-site --set name=r1
sudo morzer apply
```

With a borrowed site, `--set site=site.example.net` in place of `--domain`
and `--profile`. The relay generates its own keys at `init`, and a nonce,
from which each server derives the relay's id there. It is healthy and idle
now: it serves its site and lets nobody in.

## 3. On the relay: its line

Give `relay-entry` the address devices reach the relay at. With a domain, give
the domain: links then name it, and [moving the relay](operations.md#move-a-relay)
needs only a DNS change. Without one, give the relay's public IP:

```sh
sudo morzer task run relay-entry --output -- relay.example.net   # or 198.51.100.7
```

It prints one line, the same for every server, and the commands a
[canary](../canary/index.md) needs to check this relay:

```text
relay/1 r1 <nonce> relay.example.net relay.example.net <public key> <short id> <encryption> xhttp=<path>
```

The fields after the encryption are the relay's transports: `xhttp=` under
`own-site`, `kcp=` under `mkcp`, `hy2=` under `hysteria2`, and its CDNs'
`cdn=`, `cdnpath=` and `origin=`. The line holds what devices' links through
the relay carry, so it is as private as a device's link.

## 4. On each server: the relay's line in `relays`

On every server of each group the relay is to serve:

```sh
sudo EDITOR=nano morzer config edit relays
```

Paste the line. The server's Xray restarts, letting the relay in by an id it
derives from its own `relay_seed` and the relay's name and nonce, and the
server starts serving the relay its devices. One line per relay; a second
line with a name already there is refused.

Whether devices use the relay's links last, or not through some of its
transports, is the server's `relay_flags`, one line per relay, which
changes no relay line and restarts nothing:

```text
r1 standby
r2 off=reality split
```

`standby` keeps a relay idle while the others get through: devices hold its
links, last, but their Xray configs, dotdash-client's included, don't check
them, and send traffic through it only once every other link has failed.

## 5. On each server: its line for the relay

```sh
sudo morzer task run relay-config --output -- r1
```

It prints one line, the same on every server of the group:

```text
server/1 a a.example.com 443 <public key> <short id> <encryption> <r1's id on a>
```

The relay's id there is its way into the group's servers, so the line is a
credential. `relay-config` refuses a relay whose line is not in `relays`, or
while `name` is unset. With [several servers](../server/several-servers.md),
the line names each: `server/1 a a1.example.com,a2.example.com …`. A relay
whose provider's resolver should not see the servers' names can be given an
IP for each, in their order: add `address=203.0.113.4,203.0.113.5` to the
line.

## 6. On the relay: `servers`

```sh
sudo EDITOR=nano morzer secret edit servers
```

One line per group, each as its `relay-config` printed it. Xray restarts with
every group, and within a minute it has fetched each group's devices through
that group's own servers. A line Xray can't read keeps it from starting:
`doctor` says so at once, and `sudo docker compose -p dotdash-relay logs
xray` names the line. Fix it and save again.

## 7. Check

```sh
sudo morzer task run servers --output
```

```text
a                live     a.example.com ok 41 ms; 14 devices, digest 3f9a1c2b, list 42 s old
b                live     b.example.com ok 63 ms; 3 devices, digest 0d1e2f3a, list 42 s old
gateway: last round 18 s ago
```

A group that is `refused` has servers that answer but have no list for this
relay: its line is not in their `relays`, or its `servers` line is out of
date. `down` is no server answering. `entry-check` then tries each of the
relay's entries for each live group, as a device would
([Check each entry](operations.md#check-each-entry)).

## 8. Devices

`client-config` on each device's own server now prints a `r1 · reality`
link for the device, and the Xray config falls back to the relays when the
server itself is out of reach. Under `own-site`, a `r1 · xhttp` link joins
it: XHTTP over TLS behind the relay's site, for networks that block REALITY
over raw TCP, the transport blocked most often since early 2026.
Subscriptions pick the links up by themselves; otherwise resend them. Do it
now, while devices can still reach the server.

With subscriptions on and a relay under `own-site`, each device also gets
its subscription through the relay, which `client-config -- --relay r1
phone` prints alone:

```text
https://a.example.com/<token>
through the relay relay.example.net: https://relay.example.net/<token>
```

Give a device inside the restricted network the second one. The relay
fetches it from the device's own servers through its tunnel, so the app
keeps refreshing its links while only some addresses get through, and
nothing between the relay and the server can read them. The relay never
holds the token: it routes by its first 12 hex characters.

To check, connect a phone on the target network with its relay link alone.

A device is added to or deleted from its server's `vless_clients`, and
nothing else: the relay follows within a minute. Another server group: its
`name`, the relay's line in its `relays`, and its `relay-config` line in the
relay's `servers`. One relay serving several groups is a
[gateway](gateway.md).

Next: [keeping it running](operations.md).
