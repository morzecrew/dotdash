# dotdash 0.11.2

Nothing needs doing before updating from 0.11.1, and `morzer rollback` back to it works. It needs morzer 0.18.0, as 0.11.1 did.

- **A CDN in front:** run `cdn-check` again after updating. Behind an app as cover, an earlier one said `SERVES SUBSCRIPTIONS` for a CDN that was in fact refused; this one tells the two apart.

```sh
sudo morzer update --stage
sudo morzer update --to 0.11.2
```

### Fixed

- `cdn-check` no longer reports a CDN as serving subscriptions when an app behind the site (`cover`) answers every path: it now knows its decoy by the decoy's contents, and calls a 2xx without them refused.
