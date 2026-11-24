# OpenFlux

The way in for when nothing else gets through. Some networks let through only
a handful of services. Where neither a relay nor a CDN answers there,
[OpenFlux](https://github.com/p1neappleXpress/OpenFlux) may still work:
a device and your server meet on a room, a document or a call on one of
those services. It is slow, a second app on the device, and runs on other
companies' services, so it only sits under the other
[ways in](../ways-in.md). It never replaces them.

```sh
sudo morzer config set installation.profile=xdns,openflux    # beside the profiles you run
sudo morzer config edit openflux_channels
```

One line per device that gets a channel:

```text
# <device> <kind>[=<link>] ...
phone co
laptop tm                                    # a call made for it (below)
tablet tm=<a call link of yours>
```

- **The device** is a `vless_clients` name, or the UUID of an unnamed line.
  A device not in `vless_clients` gets no channel, and the log says so.
- **The kinds** are short names for OpenFlux's transport types. The channel's
  session runs over all of them, and carries on over the others when one
  fails.

  | Kind | What it is | Needs |
  | --- | --- | --- |
  | `tm` | a call, the fastest | a call link of yours, or one made for it ([below](#calls-made-for-you)) |
  | `co`, `av` | rooms | nothing: they make their own, once |
  | `mr`, `yd`, `yv`, `yb` | documents | a document link of yours |
- **Each channel is an exit of its own**, because an OpenFlux exit serves one
  client at a time. In the lab one took about 20 MiB idle, and 45 MiB and a
  third of a core while busy.

Then give the device its link, in the OpenFlux app (paste it, or scan a QR
code made from it):

```sh
sudo morzer task run openflux-link --output -- phone
```

The link holds the channel's key. Hand it over as you would any link
([ways in](../ways-in.md#during)).

## What it does

- **Device traffic leaves through the upstreams**, as it does from Xray: each
  exit opens its connections through the gate. UDP goes the same way where
  `upstream_udp` is on, and is dropped where it is off. Only the connections
  to the carrier, the service the rooms or documents are on, leave the server
  directly.
- **The link stays good** across restarts and releases. Each device's key,
  rooms and link are kept on the `dotdash_openflux` volume.
- **A leaked link shows itself.** A second app on the same link takes the
  channel over, and the two keep pushing each other off, so the owner sees
  outages. Delete the device from `vless_clients` and add it again with a new
  UUID: it loses its old key and rooms, and gets new ones and a new link.
  Leaving a device out of `openflux_channels` stops its channel but keeps its
  link for its return.
- **Not counted by device.** OpenFlux traffic passes the gate but not Xray, so
  the `device-traffic` profile doesn't see it.

## Calls made for you

With `call_provider=tm` and the `call_token` secret, a bare `tm` in a device's
line gets that device a call of its own, made once through the provider's API
and kept with the device's key. The waiting room is open, so the exit and the
app join with the link alone.

```sh
sudo morzer config set call_provider=tm
sudo morzer secret edit call_token    # the token alone
```

- **Calls are never deleted.** Deleting a call through the API needs the
  service's business plan, so a deleted device's call stays behind, unused:
  the device's new key makes the old link useless.
- **Use an account of its own** if you can. Every call belongs to it, so a
  ban takes them all down, and the calls tie that account to the server.

## Speed and limits

- In the lab, `tm` carried 8 Mbit/s down and 6 up with no stall, and
  more once a long transfer had it add participants. It never goes quiet:
  each side moves about 2.3 Mbit/s even idle, about 1 GB an hour.
- `co` carried 1-2 Mbit/s. Under sustained load it stalled after
  about a minute, and the channel came back on its own about 45 s later.
  That is enough for messages and pages, not for video; idle, it is near
  silent.
- `av` rooms were rejected when the exit joined them, as of OpenFlux 0.17.1.
  The log says when rooms can't be made; the channel then runs on its other
  kinds, and tries again at the next start.
- Carriers break when the services change, until OpenFlux catches up, and
  using them may break those services' terms.
- The exit and the app must speak the same OpenFlux version: a change to how
  keys are derived has broken handshakes between versions before. dotdash
  moves its OpenFlux release by hand, and says so in the changelog.
