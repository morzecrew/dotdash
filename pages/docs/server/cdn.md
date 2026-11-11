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

3. **Devices**: `client-config` prints a `phone [cdn cdn.example.net]` link,
   the Xray config gains an outbound through it, and subscriptions pick it up.
   Give devices the link before restrictions start, as with a
   [relay](../relay/index.md).

Some CDNs pass `GET` alone and no request body, so these links upload in
small `GET` requests with the data in headers (XHTTP `packet-up`). The server
needs nothing changed for it. An app that imports the link but never
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
paths and headers. VLESS Encryption keeps what they carry from it.

Don't give devices their subscription URL through the CDN
(`https://cdn.example.net/<token>`), although it would answer. The CDN would
read it in the clear: every link, the device's keys, every relay and CDN name.
One request to the provider would then list every way in. A
[relay with its own site](../relay/install.md#6-devices) serves the
subscription inside the restricted network with nothing in between reading
it.

### In front of a relay

A CDN can front a [relay with a site of its own](../relay/install.md#1-pick-the-site)
instead of this server. The CDN's account then names the relay, which is
cheap to replace, rather than this server and its upstream.

1. **At the CDN**, as above, with the relay's domain as the origin:
   `https://relay.example.net`. Like the server, the relay answers under
   any name.
2. **On the relay**, list the names devices use, then print its line again
   ([its line](../relay/install.md#4-on-the-relay-its-line)); it now ends in
   `cdn=cdn.example.net`:

    ```sh
    sudo morzer config set cdn_hosts=cdn.example.net
    sudo morzer task run relay-entry --output -- <address>
    ```

3. **Here**, replace the relay's line in `relays`
   (`sudo morzer config edit relays`). Devices get a
   `phone [relay <host> cdn cdn.example.net]` link and an outbound, shaped as
   above, and [pools](devices.md#pools) take the relay's CDN names as members.

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
