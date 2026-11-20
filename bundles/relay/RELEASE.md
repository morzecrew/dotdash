# dotdash-relay 0.11.1

Released with dotdash 0.11.1. Nothing needs doing before updating from 0.11.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.11.0 did.

- **A CDN in front:** if `cdn-check` on the server says it `SERVES SUBSCRIPTIONS` because the CDN strips the headers that say so, have the CDN send its own name as `Host` instead of the relay's domain after this update, then run `cdn-check` again. A CDN that then fails its origin's certificate check needs that check off.

```sh
sudo morzer update --stage
sudo morzer update --to 0.11.1
```

### Changed

- A relay with a site of its own serves devices' subscriptions under its own domain alone. A CDN in front that strips the headers saying it passed a request on is refused too, once it sends another name as `Host`, such as its own; `cdn-check` tells.
