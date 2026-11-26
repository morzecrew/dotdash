# dotdash-client 0.18.0

Released with dotdash 0.18.0. Nothing needs doing before updating from 0.17.0. `morzer rollback` back to it works; under `tun`, delete this release's DNS table afterwards, as 0.17.0 doesn't know it: `sudo nft delete table inet dotdash`. It needs morzer 0.17.0 or later, as 0.17.0 did.

- **Under `tun`,** DNS to a resolver off the machine, such as the router's, now goes through Xray and gets fake addresses, and the kill switch stays on while dotdash-client is updated, restarted or stopped. The [tun page](https://morzecrew.github.io/dotdash/client/tun/) shows a unit that closes the gap at boot.

```sh
sudo morzer update --stage
sudo morzer update --to 0.18.0
```

### Fixed

- A client under `tun` with no link that answers, as on a fresh install or with kept links whose server is gone, now gets its subscription: while no link answers, the fetch goes directly from Xray, outside TUN. Before, it entered TUN, found no link and was refused for good. No other process can take that way out.

- A client that starts on its kept links, because the subscription can't be fetched, fetches again every 30 seconds until it gets through, not a whole `subscription_interval` later. Kept links whose server is gone give way to the new ones within a minute.

- The client's kill switch keeps its rules while dotdash-client is updated, restarted or stopped, so the machine never gets out around dotdash then; leaving `tun` still takes them out, even after a stop. `doctor` now checks IPv6's rules too. The client's tun page shows a unit that closes the gap at boot.

- Under `tun`, DNS to any resolver not on the machine, such as the router DHCP named, gets fake addresses like the rest, whoever asks: any user, systemd-resolved, a container. It goes nowhere while Xray is down. The kill switch redirects it with nftables.

- A client's `DOMAIN-REGEX` rule keeps its commas, as in `^a{2,3}`. It was cut at the first one, which Xray refused, so the change rolled back.
