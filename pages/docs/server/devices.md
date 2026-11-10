# Devices

Each device has its own id, a `<uuid> [name]` line in the `vless_clients`
secret. `init` creates the first; add one per device:

```sh
uuidgen                                          # a new id
sudo EDITOR=nano morzer secret edit vless_clients  # add "<uuid> phone"; Xray restarts on save
```

## Links and the Xray config

```sh
sudo morzer task run client-config --output             # every device
sudo morzer task run client-config --output -- phone    # one
```

Per device it prints:

- an XHTTP link and a REALITY link, `phone [xhttp]` and `phone [reality]`,
  for each server; `phone [xhttp+reality]` with
  [XHTTP with REALITY](xhttp-reality.md) on; `phone [kcp]` with
  [mKCP](mkcp.md) on; and `phone [relay <host>]` for
  each [relay](../relay/index.md), with `phone [relay <host> xhttp]` before it
  through a relay with a site of its own, and `phone [relay <host> kcp]`
  after it through a relay with mKCP. XHTTP comes first everywhere: an
  app tends to try the first link, and REALITY over raw TCP is the transport
  blocked most often;
- an Xray config for v2rayN or v2rayNG (as a custom config) that uses
  whichever link answers fastest, drops a dead one within about 30 s, and
  falls back to the [DNS tunnel](dns-tunnel.md) when it is on.

!!! warning "The output is a password"
    Anyone holding a device's links can use the server as that device.

As QR codes in the terminal, with `qrencode`:

```sh
sudo morzer task run client-config --output -- phone | grep '^vless://' |
  while read -r link; do qrencode -t ansiutf8 "$link"; done
```

How each app handles DNS: [DNS on devices](device-dns.md).

## Subscriptions

With subscriptions on, each device gets one URL instead, and fetches its
links from it:

```sh
sudo morzer config set subscription=true
sudo morzer task run client-config --output -- phone           # its URL only
sudo morzer task run client-config --output -- --full phone    # plus links and the Xray config
```

- Add the URL as a subscription in the app (v2rayN, v2rayNG, Hiddify, Happ,
  Streisand) and refresh every few hours: revocations, key rotations and new
  relays then reach devices with nothing to resend.
- mihomo reads the URL as an `http` proxy provider; the
  [client bundle](../client/index.md) runs it on a Linux machine for you.
- A URL is as secret as the links. `sudo morzer secret rotate subscription_key`
  moves every URL; any other path gets the site's 404.
- A [relay](../relay/install.md#6-devices) with a site of its own serves the
  same subscription inside the country: `client-config` adds a
  `through the relay …` URL under the server's. An app takes one URL, so give
  a device inside the country the relay's.
- Never give a device its subscription through a [CDN](cdn.md): the CDN
  would read every link.

The official sing-box apps, Karing and NekoBox can't connect to dotdash: they
lack VLESS Encryption and the key share Xray's REALITY requires.

## Pools

Every device gets every [relay](../relay/index.md) and [CDN](cdn.md) host, so
one leaked device gives away all of them. Pools split them: a device in a
pool gets its pool's relays and CDN hosts, and those in no pool. One line per
pool in the `pools` parameter: the pool's name, then its devices (their names
as written in `vless_clients`), relay hosts (as in `relays`) and CDN hosts:

```sh
sudo morzer config edit pools
```

```text
family  mom dad relay1.example.ru cdn1.example.ru
friends anna boris relay2.example.ru
```

- A device in no pool, or without a name, gets every relay and CDN host, as
  before. A relay or CDN host in no pool goes to every device.
- A device, relay or CDN host may be in several pools.
- `client-config` and the subscriptions follow the change. A device that
  fetched its links before keeps them until it refreshes, and a device's
  links work through any relay, so pools hide entry points rather than lock
  devices out of them.
- `client-config` names a member that matches no device, relay or CDN host:
  a typo would otherwise leave a device in no pool, and so give it everything.

Replacing a pool's relay then means new links only for that pool's devices.

## Revoking a device

Delete its line from `vless_clients`. A revoked device still knows the
shared keys; to hide the server from it too, rotate them and resend links
(subscriptions pick them up):

```sh
sudo morzer secret rotate reality_key
sudo morzer secret rotate vless_seed
```

With [relays](../relay/index.md) or [several servers](several-servers.md),
change their copies too.
