# Devices

Each device has its own id, a `<uuid> [name [desktop|mobile]]` line in the
`vless_clients` secret. `init` creates the first; add one per device:

```sh
uuidgen                                          # a new id
sudo EDITOR=nano morzer secret edit vless_clients  # add "<uuid> phone"; Xray restarts on save
```

### Desktops

A device whose line ends in `desktop` gets no CDN link: neither through the
CDNs in front of the server (`cdn_hosts`) nor through a relay's (its `cdn=`
and `origin=`), and nothing through a relay that offers CDN links alone.
CDNs are for restricted mobile networks, and some are paid by the gigabyte,
where a desktop moves the most. Its other links stay. `mobile`, or no word,
gets every link.

```text
0593b52c-b345-41cb-96b8-134724f6ca65 phone
1b2c3d4e-5f60-4718-8a9b-0c1d2e3f4a5b laptop desktop
```

A changed kind reaches the device with its next subscription fetch. It
picks links, it doesn't lock any: a CDN link the device already holds, handed
over by hand, still works. A kind needs a name before it. Relays running a
release from before kinds refuse such a line, and `relay-config` copies it to
them, so update them before giving a device a kind.

## Links and the Xray config

```sh
sudo morzer task run client-config --output             # every device
sudo morzer task run client-config --output -- phone    # one
```

Per device it prints:

- an XHTTP link and a REALITY link, `server · xhttp` and `server · reality`,
  for each server; `server · xhttp+reality` with
  [XHTTP with REALITY](xhttp-reality.md) on; `server · kcp` with
  [mKCP](mkcp.md) on; `server · hy2` with [Hysteria2](hysteria2.md) on; and
  `relay · reality` for each [relay](../relay/index.md), with
  `relay · xhttp` before it through a relay with a site of its own,
  `relay · cdn` after that through each
  [CDN in front of it](cdn.md#in-front-of-a-relay), `relay · hy2`
  after it through a relay with Hysteria2, and `relay · kcp`
  through a relay with mKCP; `server · cdn` through each CDN in front of the
  server. XHTTP comes first everywhere: an app tends to
  try the first link, and REALITY over raw TCP is the transport blocked most
  often. A link is named `<route> · <transport>`, without the device's name:
  its subscription is its own, and the app shows the protocol beside it.
  Where there are several, each is numbered, `relay 1 · cdn 2`: a
  relay by its place among the `relays` lines, a CDN by its place in
  `cdn_hosts` (or in its relay's `cdn=`), the same on every device, so an
  app shows no host name; with several servers, `server 1`, `server 2` and
  on, in the order of `servers`. A relay with a
  [name](../relay/reference.md#parameters) goes by it instead: `edge-1 · reality`;
- an Xray config for v2rayN or v2rayNG (as a custom config) that uses
  whichever link answers fastest, drops a dead one within about 30 s, and
  falls back to the [DNS tunnel](dns-tunnel.md) when it is on, or to a
  `standby` relay's links, unchecked until then, when there is one.

!!! warning "The output is a password"
    Anyone holding a device's links can use the server as that device.

As QR codes in the terminal, with `qrencode`:

```sh
sudo morzer task run client-config --output -- phone | grep '^vless://' |
  while read -r link; do qrencode -t ansiutf8 "$link"; done
```

How each app handles DNS: [DNS on devices](device-dns.md).

### Apps that look for a VPN

Some apps on a phone look for a VPN, and refuse to run or report it. One way
they look is to try the local proxy ports an app like v2rayNG opens: with no
password there, they get through, and see the exit's address.

- **v2rayNG with links or a subscription:** in its settings, set a "Local
  proxy username" and "password" (any you like); v2rayNG then puts them on its
  own local proxy. Keep such apps off the proxy with its per-app settings.
- **v2rayNG with the Xray config:** print the config with `--local-auth`:

    ```sh
    sudo morzer task run client-config --output -- --local-auth phone
    ```

    Its local SOCKS takes the user `dotdash` and a password printed with it,
    the same on every run. Enter both in v2rayNG's settings, or the device
    gets nowhere. It has no HTTP proxy on 10809, which only v2rayN's system
    proxy uses: give v2rayN the plain config.
- An app kept off the proxy can still tell that a VPN is on from the phone's
  network interfaces. Only putting it in a separate work profile or user
  hides that.

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
  relays then reach devices with nothing to resend. The URL asks for a fetch
  every 6 hours (`Profile-Update-Interval`), which the apps that read it
  (Happ, Hiddify) follow on their own; in the others, turn on
  automatic updates.
- **Happ's routing:** `happ_routing` takes a routing profile in Happ's own
  JSON, and every subscription then carries it. Happ adds it, turns it on, and
  takes it again with each refresh, so the sites and addresses it lists as
  direct go around the tunnel on every Happ device: quicker, and they never
  see the server's exit. Other apps ignore it. For example, with a geosite
  list of your country's sites (any `geosite.dat` with one, by URL):

    ```sh
    sudo morzer config set --set-file happ_routing=- <<'END'
    {"Name": "dotdash", "GlobalProxy": "true",
     "Geositeurl": "https://example.net/geosite.dat", "Geoipurl": "https://example.net/geoip.dat",
     "DirectSites": ["geosite:<your-list>"], "DirectIp": ["geoip:private", "geoip:<your-list>"],
     "DomainStrategy": "IPIfNonMatch"}
    END
    ```

    Happ fetches the geo files itself, at most weekly. `none` stops sending
    it; a device keeps the profile it has until it is removed in the app.
- An app on Apple's network stack (its User-Agent names CFNetwork, Darwin, iOS
  or macOS, as Shadowrocket's, Streisand's and Happ's on iOS do) gets the links
  with Safari's TLS hello (`fp=safari`), as its own platform sends; every other
  app, Chrome's. A Chrome hello from an iPhone fits neither its network stack
  nor its browser.
- The apps that show a subscription's name (Happ, Hiddify) show the
  server's exit, its country's flag and IPv4 address, as the sites the device
  visits see it, in place of the server's domain. The server asks for it
  through the upstreams every ten minutes (`exit_ipv4_url`, `exit_info_url`),
  so after a line fails over, the next refresh shows the new exit. With
  `upstream_mode=balance` the exit changes between connections, and the name
  shows one of them.
- Hiddify reads XHTTP links with its own core, which takes `mode=auto` as
  `packet-up` and ignores a `mode` in the link: long uploads through them can
  hang there. In Hiddify, use the REALITY or Hysteria2 link.
- The same URL, asked with `Accept: application/json`, serves the device's
  Xray config: the [client bundle](../client/index.md) runs Xray on it on a
  Linux machine for you. On its REALITY links, the device's UDP flows share
  a few connections (XUDP Mux) rather than opening one each. On every TCP
  link, a connection whose sent data goes unacknowledged for 15 seconds is
  given up and redialled: a connection the network has frozen, which XHTTP
  would otherwise keep sending requests down for a minute.
- A URL is as secret as the links. `sudo morzer secret rotate subscription_key`
  moves every URL; any other path gets the site's 404.
- A [relay](../relay/install.md#6-devices) with a site of its own serves the
  same subscription inside the restricted network: `client-config` adds a
  `through the relay …` URL under the server's. An app takes one URL, so give
  a device inside the restricted network the relay's.
- Never give a device its subscription through a [CDN](cdn.md): the CDN
  would read every link.

The official sing-box apps, Karing and NekoBox can't connect to dotdash: they
lack VLESS Encryption and the key share Xray's REALITY requires.

## Pools

Every device gets every [relay](../relay/index.md) and [CDN](cdn.md) host, so
one leaked device gives away all of them. Pools split them: a device in a
pool gets its pool's relays and CDN hosts, and those in no pool. One line per
pool in the `pools` parameter: the pool's name, then its devices (their names
as written in `vless_clients`), relay hosts (as in `relays`) and CDN hosts,
a relay's own (its `cdn=` names) included:

```sh
sudo morzer config edit pools
```

```text
family  mom dad relay1.example.net cdn1.example.net
friends anna boris relay2.example.net
```

- A device in no pool, or without a name, gets every relay and CDN host, as
  before. A relay or CDN host in no pool goes to every device.
- A relay's CDN hosts go only to devices that get the relay.
- A device, relay or CDN host may be in several pools.
- `client-config` and the subscriptions follow the change. A device that
  fetched its links before keeps them until it refreshes, and a device's
  links work through any relay, so pools hide entry points rather than lock
  devices out of them.
- `client-config` names a member that matches no device, relay or CDN host:
  a typo would otherwise leave a device in no pool, and so give it everything.

Replacing a pool's relay then means new links only for that pool's devices.

## Keeping the servers out of devices' links

Pools hide relays and CDN hosts, but every device still gets the servers'
own links, so one leaked device gives away every server. With `direct=false`
devices get no server's address at all:

```sh
sudo morzer config set direct=false
```

- Links and the Xray config go through relays and CDN hosts only.
- The subscription URL is printed only through own-site relays, never on the
  server's domain.
- The DNS tunnel goes: its zone is delegated to a server, so a lookup of it
  names the address.
- A device that gets no relay and no CDN host gets no links, and one with no
  own-site relay no subscription URL. `client-config` names each.

Set it on every server alike: they print the same links. Relays then take
the risk, and a burnt one is replaced the way a pool's is, while the servers
keep their addresses. As with pools, a device that knew a server's address
still reaches it: `direct=false` hides the servers, it does not lock devices
out. To hide them from such a device too, rotate the shared keys as for
[revoking](#revoking-a-device) one.

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
