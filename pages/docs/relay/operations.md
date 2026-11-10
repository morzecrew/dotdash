# Running a relay

The relay keeps copies of what it got from the server: the devices, and the
server's keys. Whatever changes one side has to reach the other.

## Devices

A device added to or deleted from the server's `vless_clients` has to
change on the relay too. After the change on the server, `relay-config`
prints the relay's new copy:

```sh
# on the server
sudo morzer task run relay-config --output -- relay
# on the relay: the vless_clients block of that output
sudo morzer secret set vless_clients <<'END'
…
END
```

## Keys

| What changed | What to do |
| --- | --- |
| The server's `reality_key`, `vless_seed` or `reality_short_id` | Run `relay-config` again, and on the relay set `dotdash_public_key`, `dotdash_encryption` and `dotdash_short_id` from it. Until then the relay can't reach the server. |
| The relay's own keys (`secret rotate` on the relay) | Run `relay-entry` again, replace the relay's line in the server's `relays`, and send devices their links again (subscriptions pick them up). |
| The relay's address | The same: `relay-entry -- <new address>`, then replace the line. |

## A site of its own, later

A relay set up with a borrowed site moves to one of its own in place. Point a
domain at it and open port 80, then:

```sh
sudo morzer config set installation.domains=relay.example.ru
sudo morzer config set installation.profile=own-site
sudo morzer task run relay-entry --output -- 198.51.100.7
```

The site in the line changes and the line gains `own-site`, so replace the
relay's line in the server's `relays`, and send devices their links again
(subscriptions pick them up), with the subscription URL through the relay for
those inside the country.
`sudo morzer config unset installation.profile` goes back to the borrowed
site.

## Servers

The relay goes to every server in `dotdash_servers` and uses whichever
answers fastest. With a [new server](../server/several-servers.md) sharing
the keys:

```sh
sudo morzer config set dotdash_servers=example.com,b.example.com
```

Under `own-site`, `sudo morzer apply` afterwards: the site fetches
subscriptions from these servers, and only an apply restarts it with the new
list.

## Move a relay

A relay whose links name its domain moves to a new machine, or a new address,
with a DNS change, and devices keep their links. It keeps its keys, which a
backup holds. Prepare when you set it up: keep the recovery key off the
machine, add a backup target, and set the `A` record's TTL to 300 s or less.

```sh
sudo morzer secret set backup_s3 < ./bucket.yaml   # the bucket's credentials
sudo morzer backup target add s3://bucket/dotdash-relay --credentials backup_s3
sudo morzer backup                                  # one now; each update takes another
```

Then, on the new machine, after `bootstrap.sh`:

```sh
sudo morzer --product dotdash-relay installation import --from-backup \
  --target s3://bucket/dotdash-relay --credentials-file ./bucket.yaml \
  --identity ~/relay-recovery.key
sudo morzer update oci://ghcr.io/morzecrew/dotdash-relay:stable
```

Point the relay's domain at the new address, and open 443, and 80 under
`own-site`. Shut the old machine down: two live relays with one installation
id confuse each other's backups. A relay whose links name its IP needs a new
line from `relay-entry` in the server's `relays`, and new links for devices.

## Watching it

`doctor` and each `apply` fetch `probe_url` through dotdash, so they fail
when the relay can't reach the server. Have them alert you:

```sh
sudo morzer notify target add https://hooks.example/morzer
```

What the relay can't see is whether devices reach it: only a machine on the
networks devices use can. A [canary on a mobile line](../canary/index.md#on-a-mobile-line)
checks the relay as it checks a server, with the commands `relay-entry` prints.

## Updates

As for the server: `sudo morzer self-update` when a release needs a newer
morzer, then `sudo morzer update --stage && sudo morzer update --to <version>`.
Unattended updates follow
`update.channel=oci://ghcr.io/morzecrew/dotdash-relay:stable`; see
[Operations](../server/operations.md#unattended-updates).
