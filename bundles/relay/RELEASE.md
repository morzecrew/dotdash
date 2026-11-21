# dotdash-relay 0.11.2

Released with dotdash 0.11.2. Nothing needs doing before updating from 0.11.1, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.11.1 did.

- **A CDN in front:** check it with `cdn-check` on a 0.11.2 server, which no longer mistakes an app as cover for a CDN that is served. Only a CDN it still says `SERVES SUBSCRIPTIONS` for needs another name as `Host` (0.11.1); if it then can't reach the relay, send a name under the relay's wildcard.

```sh
sudo morzer update --stage
sudo morzer update --to 0.11.2
```

### Fixed

- A relay's XHTTP path drops the client address a CDN in front passes on in `X-Real-IP` or `CF-Connecting-IP`, as the server's does, so it no longer reaches the relay's Xray.
