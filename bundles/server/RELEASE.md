# dotdash 0.15.0

Nothing needs doing before updating from 0.14.0, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.14.0 did.

- **Devices running the Xray config from `client-config`** get fake DNS once they import it again (`sudo morzer task run client-config --output -- --full phone`). Links and subscriptions are unchanged.

```sh
sudo morzer update --stage
sudo morzer update --to 0.15.0
```

### Changed

- client-config's Xray config answers devices' DNS with fake DNS, as dotdash-client's TUN does: a name gets a stand-in address at once and the server looks it up, so a first visit to a name no longer waits for a lookup through the tunnel (53 ms less in the lab). `dns_resolver` is now the server's alone.
