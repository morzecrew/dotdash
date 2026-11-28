# CDN

A CDN in front of this server carries XHTTP for it, and serves two different
ends:

- a **local CDN**, for networks that let only some addresses through: its
  edges are inside such a network and get through, and this server does not;
- a **CDN against address blocking**: devices see only the CDN's addresses,
  never this server's.

## A local CDN, for restricted networks

While a network lets only some addresses through, a CDN whose edges are among
them can still reach this server: devices connect to the CDN's edge, and the
CDN fetches from `https://example.com`.

1. **At the CDN**, create a resource with this server as its origin:
   - origin `https://example.com`. The `Host` header can stay at the
     CDN's default: this server answers under any name. If the CDN checks
     the origin's certificate against a name of its own and fails, have it
     send `example.com` as the `Host`, or as the origin's name;
   - no caching, and HTTP/2 towards devices if it is offered;
   - a name devices use: the provider's own name for the resource, or a
     domain of yours pointed at it, with the certificate it asks for.
2. **Here**, list the names devices use, comma-separated:

    ```sh
    sudo morzer config set cdn_hosts=cdn.example.net
    ```

3. **Devices**: `client-config` prints a `server · cdn` link,
   the Xray config gains an outbound through it, and subscriptions pick it up.
   Give devices the link before restrictions start, as with a
   [relay](../relay/index.md).

Some CDNs pass `GET` alone and no request body, so these links upload in
small `GET` requests with the data in headers (XHTTP `packet-up`), 8 KiB at
most each, under the 20 KB or so of headers a CDN takes. The server needs
nothing changed for it. An app that imports the link but never
connects may read its `extra` settings differently; the Xray config works
in v2rayN and v2rayNG.

!!! warning "Fragile"
    CDNs like these break without notice, and providers act on proxy and VPN
    use: some refuse requests with a body, some forbid proxies in their terms,
    some block traffic that looks like a VPN, and an edge can stop getting
    through from one week to the next. Read the provider's terms, test from
    the networks your devices use, keep a CDN as one way among several, and
    expect the account to be closed.

To make losing an account cheap:

- **Spread over CDNs and accounts.** `cdn_hosts` takes several names, and the
  Xray config passes over one that stops answering. Don't put every device
  behind one account: [pools](devices.md#pools) give each group of devices
  its own CDN hosts.
- **Serve a real site at the origin** ([cover site](cover-site.md)). It is
  what the CDN fetches and what a provider's reviewer sees. Operators report
  that accounts with a live, visited site behind them last longer than
  those fronting the bundled page.

The CDN ends one TLS connection and opens another, so it sees the requests'
paths and headers. VLESS Encryption keeps what they carry from it. The links
go by a path of the CDNs' own (the `cdn_xhttp_path` secret, made at the
first apply), never the one devices reach this server by directly, disguised
as [through a relay](#in-front-of-a-relay): one path, the session, sequence
and padding in cookies, no protocol marker by name. Devices on a
subscription take these links at their next refresh. Links imported by hand
before them take the direct path through the CDN, plain, which still works:
send those devices their links again.

A CDN is refused subscriptions. A subscription read in the clear gives away
every link, the device's keys and every relay and CDN name, so one request
to the provider would list every way in. The server and
[relays with their own site](../relay/install.md#8-devices) answer a
subscription request a CDN passed on with the site, as any other path: its
404, or your app's answer. They recognise
one by the headers a CDN adds to say so (`X-Forwarded-For`, `Via`, `Forwarded`
and the like), which a device asking directly never sends. A CDN that adds
none of them would still get one. If yours lets you add headers to its
requests to the origin, add one of them, so every request it passes on says
so: `CDN-Loop` is the one made for this, with any value, such as
`CDN-Loop: edge`. Keep the value plain: the CDN's account shows it.

Some CDNs strip such headers, even ones you add. A relay serves subscriptions
under its own domain alone, the name devices ask by, so in front of a relay
have the CDN send any other name as `Host`: its own name, or its default. A
CDN that checks the origin's certificate against that name then can't reach
the relay; with a [wildcard](certificates.md) on the relay, send another name
under it. Then check:

```sh
sudo morzer task run cdn-check --output
```

It fetches a decoy subscription, with no links in it, through each CDN in
front of this server and of its relays, and prints `refused` for each, or
`SERVES SUBSCRIPTIONS` for one that got it. It knows the decoy by its
contents, so an app behind the site that answers every path doesn't pass for
it. Keep such a CDN's name away from
devices' subscriptions: an own-site relay serves them inside the restricted
network with nothing in between reading them.

`cdn-check` also asks each name, a relay's `origin=` names included, on the
path its links take, with no session, which Xray turns down with a 400 where
the site answers a path that leads nowhere with its 404. So for each name it
says whether the data path reaches Xray behind it; ends at the site's 404,
when the relay's line here is stale or a [door](#a-cdn-that-fetches-in-plain-http)
refused the CDN's address; or gets a 5xx or no answer, when the CDN doesn't
reach its origin. It exits 1 if a CDN serves subscriptions or a path doesn't
reach Xray. Run it on demand: it fetches through the upstreams, and a fetch
of every CDN each hour would be a pattern of its own.

### In front of a relay

A CDN can front a [relay with a site of its own](../relay/install.md#1-pick-the-site)
instead of this server. The CDN's account then names the relay, which is
cheap to replace, rather than this server and its upstream.

1. **At the CDN**, as above, with the relay's domain as the origin:
   `https://relay.example.net`. Like the server, the relay answers under
   any name.
2. **On the relay**, list the names devices use, then print its line again
   ([its line](../relay/install.md#3-on-the-relay-its-line)); it now ends in
   `cdn=cdn.example.net cdnpath=…`:

    ```sh
    sudo morzer config set cdn_hosts=cdn.example.net
    sudo morzer task run relay-entry --output -- <address>
    ```

3. **Here**, replace the relay's line in `relays`
   (`sudo morzer config edit relays`). Devices get a
   `relay · cdn` link and an outbound, shaped as
   above, and [pools](devices.md#pools) take the relay's CDN names as members.

A CDN reads every request it passes on, and keeps logs. Through a relay too, the
links go by a path of the CDNs' own, so the CDN never learns the path devices
reach the relay by directly, and they are disguised: one path, the session,
sequence and padding in cookies, the padding a random token rather than a run
of `X`, the upload under a plain header name and no event-stream type on the
download, so no marker of the protocol shows by name. What it cannot hide is
the shape: one visitor sending a stream of small requests beside one long
download. Keep CDN links a fallback, front a relay you can replace (below),
and expect a CDN account to be closed one day. A relay's line from before
0.12.0, without `cdnpath=`, gives the plain links by its own path. A
[dotdash-client](../client/reference.md) with `cdn=skip` leaves CDN links
out while it has any other. `off=cdn:<name>` on the relay's line takes that one CDN's
links out of devices' and keeps the relay's others: for a CDN that gets
nothing through, as its canaries [find](../canary/index.md#a-relays-cdns).

#### The CDN's origin only

Devices behind a CDN connect to the CDN's addresses, never to the relay's, so
the relay behind it is not exposed the way a relay devices reach directly is.
Unless you say otherwise, though, the relay's line still gives devices
REALITY, XHTTP and mKCP links to its own address, which exposes it. With
`cdn_only=true`, devices get its CDN links alone:

```sh
sudo morzer config set cdn_only=true
sudo morzer task run relay-entry --output -- <address>   # now ends in cdn-only
```

Replace the relay's line here again. The relay then gives devices no link or
subscription URL of its own. The [manager](../manager.md#burnt-relays) then
judges it by its CDNs alone, which its canaries
[check](../canary/index.md#a-relays-cdns), not by its own address. `relay-entry`
refuses `cdn_only` without `cdn_hosts`, because devices would get nothing
through the relay.

A network then needs one or two CDNs in all, not one per relay. Each CDN
fronts one origin relay, with `cdn_only=true`, and the relays devices reach
directly need no CDN. A CDN's origin is one host. If that relay is lost,
point the CDN at another relay with a site of its own, and move `cdn_hosts`
and `cdn_only` to it. The name devices use stays the same.

#### A CDN that fetches in plain HTTP

Some CDNs rented for restricted networks end TLS at their own edge and fetch
the origin in plain HTTP, from an address and port you give them, and from
gateway addresses they list. A relay lets them in through a door of its own,
the `http-origin` profile: a plain-HTTP port that answers those addresses
alone, on the CDNs' path alone, and passes nothing else.

1. **On the relay**, turn the profile on and name the CDN's gateways, then
   print its line:

    ```sh
    sudo morzer config set installation.profile=own-site,http-origin \
      http_origin_from=198.51.100.10,198.51.100.11
    sudo morzer task run relay-entry --output -- <address>
    ```

    Below the line, `relay-entry` prints the port the CDN fetches
    (`http_origin_port`, 8880 by default) and the `xhttpSettings` to give the
    CDN where it asks for the node's. Open that port in the provider's
    firewall.
2. **At the CDN**, give the relay's address, the port and those settings. It
   gives back the name devices use.
3. **On the relay**, set that name and print the line again; it now ends in
   `cdnpath=… origin=abc123.cdn.example.net`:

    ```sh
    sudo morzer config set http_origin_host=abc123.cdn.example.net
    sudo morzer task run relay-entry --output -- <address>
    ```

    Where the CDN gives more than one name, a spare for when one is blocked,
    set them all, comma-separated: `http_origin_host=abc123.cdn.example.net,alt.cdn.example.net`.

4. **Here**, replace the relay's line. Devices get a `relay · cdn` link
   and outbound through each name, uploading 4 KiB at a time, which
   such CDNs pass where 8 KiB fail. With several CDN names, the links are
   numbered: `relay · cdn 1`, `relay · cdn 2`.

Some CDNs also give a name with a path and XHTTP settings of their own:
often a name shared by every customer, in front of a gateway that turns your
path and settings back into the relay's on the way. Set the name with its
path on the relay, and the settings here in `cdn_extra`, as the CDN gives
them:

```sh
# on the relay
sudo morzer config set http_origin_host=abc123.cdn.example.net,edge.example.net/e/k3y/s/
# here
sudo morzer config set --set-file cdn_extra=- <<'END'
edge.example.net {
  "mode": "packet-up",
  "uplinkHTTPMethod": "GET",
  "uplinkDataPlacement": "header",
  "uplinkChunkSize": 4096,
  "scMaxEachPostBytes": 4096,
  "xPaddingObfsMode": true
}
END
```

Links and outbounds through `edge.example.net` then take that path and those
settings in place of dotdash's. `cdn_extra` takes one such block for each
name that needs one: a name in `cdn_hosts`, or in a relay's `cdn=` or
`origin=`. The settings must suit the inbound behind the name, unless the
CDN's gateway turns them back as above. Settings Xray refuses are left out,
and the warning says so. An app whose Xray is older than the settings need
fails this link alone. A CDN that fetches the relay directly, with no
gateway, needs `http_origin_from=any` (below).

What to keep in mind:

- The CDN and its gateways read every request in the clear, paths and
  headers included. VLESS Encryption keeps what the requests carry
  unreadable, and the door's path is the CDNs' own, so the path devices reach
  the relay by directly stays unknown to them. Use a relay inside the
  restricted network: the plain-HTTP leg from the gateways then stays inside
  it.
- The gateways' addresses change. When the CDN lists new ones, set
  `http_origin_from` again; until then the door answers no one, and these
  links alone fail. `http_origin_from=any` answers every address, for a CDN
  whose edges fetch directly and publish no list: the path and the devices'
  ids are then all that keep anyone else out.
- Everyone else gets a 404 from that port.

## A CDN against address blocking

The XHTTP link works through a CDN that proxies HTTP/2 to
`https://example.com`: put the CDN's name in the link's address. Check its
terms first: many CDNs forbid proxies.

### ECH

With a CDN that offers ECH, the TLS handshake shows the CDN's public ECH name
instead of `example.com`. Add that name to the XHTTP link, before the `#`
(v2rayN ≥ 7.17, v2rayNG ≥ 2.0). `ech.example.net` stands for it here, and the
DNS-over-HTTPS URL after it is where the app looks up its keys:

```text
&ech=ech.example.net%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query
```

In the Xray config, add the same to that outbound's `tlsSettings`:

```json
"echConfigList": "ech.example.net+https://1.1.1.1/dns-query"
```

With ECH set, the connection fails rather than falling back to plain SNI.
