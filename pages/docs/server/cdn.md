# CDN

The XHTTP link works through a CDN that proxies HTTP/2 to
`https://example.com`: put the CDN's name in the link's address. Check its
terms first; Cloudflare's self-serve plans forbid proxies.

## ECH through Cloudflare

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
