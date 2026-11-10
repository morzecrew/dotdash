# Moving to a new server

Prepare: keep the recovery key off the machine, add a backup target, and set
the `A` record's TTL to 300 s or less. Devices keep their links.

```sh
# on the new server, after bootstrap.sh
sudo morzer --product dotdash installation import --from-backup \
  --target s3://bucket/dotdash --credentials-file ./bucket.yaml \
  --identity ~/dotdash-recovery.key
sudo morzer update oci://ghcr.io/morzecrew/dotdash-server:stable
# optional, keeps Caddy's certificate (import prints both ids)
sudo morzer backup fetch <backup id>
sudo morzer restore --force --confirm <installation id> --identity ~/dotdash-recovery.key
```

Then point `example.com` (and `ns.example.com`) at the new IP and shut the old
machine down: two live servers with one installation id confuse each other's
backups.
