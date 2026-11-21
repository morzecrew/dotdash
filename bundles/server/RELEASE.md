# dotdash 0.11.3

Nothing needs doing before updating from 0.11.2, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.11.2 did.

- **CDN links:** apps pick up the smaller uploads at their next subscription refresh. A CDN link imported by hand keeps the old size, and its larger uploads keep failing, until it is imported again.

```sh
sudo morzer update --stage
sudo morzer update --to 0.11.3
```

### Fixed

- CDN links upload at most 8 KiB per request instead of 32 KiB. Base64-encoded into headers, 32 KiB came to about 44 KB, past the 20 KB or so of headers CDN edges take, so any larger upload got a 431 and broke its connection.
