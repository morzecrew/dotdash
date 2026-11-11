# CDN

A CDN in front of this server carries XHTTP for it, and serves two different
ends:

- a **domestic CDN**, for mobile allowlists: its edges inside the country
  are on the lists, and this server abroad is not;
- a **foreign CDN** such as Cloudflare, against blocking of this server's
  address: devices see only the CDN's.

## A domestic CDN, for allowlists

While only allowlisted addresses get through, a domestic CDN whose edges
are on the list can still reach this server: devices connect to the CDN's
edge, and the CDN fetches from `https://example.com` abroad.

1. **At the CDN**, create a resource with this server as its origin:
   - origin `https://example.com`, with the `Host` header sent to it set
     to `example.com`;
   - no caching, and HTTP/2 towards devices if it is offered;
   - a name devices use: the provider's own name for the resource, or a
     domain of yours pointed at it, with the certificate it asks for.
2. **Here**, list the names devices use, comma-separated:

    ```sh
    sudo morzer config set cdn_hosts=cdn.example.ru
    ```

3. **Devices**: `client-config` prints a `phone [cdn cdn.example.ru]` link,
   the Xray config gains an outbound through it, and subscriptions pick it up.
   Give devices the link before a shutdown, as with a
   [relay](../relay/index.md).

Such CDNs pass `GET` alone and no request body, so these links upload in
small `GET` requests with the data in headers (XHTTP `packet-up`). The server
needs nothing changed for it. An app that imports the link but never
connects may read its `extra` settings differently; the Xray config works
in v2rayN and v2rayNG.

!!! warning "Fragile, as of November 2026"
    Every one of these has broken for someone, and providers act on VPN use:

    | CDN | Seen |
    | --- | --- |
    | Yandex Cloud CDN | worked from an MTS SIM during restrictions in October; answers 413 to any request with a body since 2026-09-28, which these links avoid; mobile outages since 2026-11-02; its terms let it block on state instruction |
    | VK Cloud CDN | `GET` only; its terms forbid proxies and VPNs |
    | Selectel CDN | VPN use unsupported, and may be blocked |
    | Timeweb, Beget | 403 to VPN-like traffic reported, and questions from support |
    | MWS | dropped from the allowlists in August |

    The ministry asked CDNs on 2026-08-31 to move allowlisted resources into
    subnets of their own. Test from a SIM on the networks you care about,
    keep a CDN as one way among several, and expect the account to be closed.

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
(`https://cdn.example.ru/<token>`), although it would answer. The CDN would
read it in the clear: every link, the device's keys, every relay and CDN name.
One request from the state to the provider would then list every way in. A
[relay with its own site](../relay/install.md#6-devices) serves the
subscription inside the country with nothing in between reading it.

### In front of a relay

A CDN can front a [relay with a site of its own](../relay/install.md#1-pick-the-site)
instead of this server. The CDN's account then names the relay, which is
cheap to replace, rather than this server and its upstream.

1. **At the CDN**, as above, with the relay's domain as the origin:
   `https://relay.example.ru`, with the `Host` header sent to it set to
   `relay.example.ru`.
2. **On the relay**, list the names devices use, then print its line again
   ([its line](../relay/install.md#4-on-the-relay-its-line)); it now ends in
   `cdn=cdn.example.ru`:

    ```sh
    sudo morzer config set cdn_hosts=cdn.example.ru
    sudo morzer task run relay-entry --output -- <address>
    ```

3. **Here**, replace the relay's line in `relays`
   (`sudo morzer config edit relays`). Devices get a
   `phone [relay <host> cdn cdn.example.ru]` link and an outbound, shaped as
   above, and [pools](devices.md#pools) take the relay's CDN names as members.

## A foreign CDN, against IP blocking

The XHTTP link works through a CDN that proxies HTTP/2 to
`https://example.com`: put the CDN's name in the link's address. Check its
terms first; Cloudflare's self-serve plans forbid proxies.

### ECH through Cloudflare

ECH also hides `example.com` from the network: the TLS handshake then shows
`cloudflare-ech.com`. Cloudflare turns ECH on by default. Add it to the XHTTP
link, before the `#` (v2rayN ≥ 7.17, v2rayNG ≥ 2.0):

```text
&ech=cloudflare-ech.com%2Bhttps%3A%2F%2F1.1.1.1%2Fdns-query
```

In the Xray config, add the same to that outbound's `tlsSettings`:

```json
"echConfigList": "cloudflare-ech.com+https://1.1.1.1/dns-query"
```

With ECH set, the connection fails rather than falling back to plain SNI.
