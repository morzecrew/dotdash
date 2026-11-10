# dotdash-relay 0.5.1

Released with dotdash 0.5.1, with no changes of its own. It needs morzer 0.15.0, as 0.5.0 did:

```sh
sudo morzer update --stage
sudo morzer update --to 0.5.1
```

dotdash 0.5.1 fixes the setup its `relay-config` task prints for a relay: the last step, `relay-entry`, now includes `--output`, without which morzer showed nothing.
