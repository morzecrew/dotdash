# dotdash-acme-dns 0.18.0

Released with dotdash 0.18.0. Nothing needs doing before updating from 0.17.0, and `morzer rollback` back to it works once `registration` is unset (`sudo morzer config unset registration`), if you set it. It needs morzer 0.17.1 or later, as 0.17.0 did.

- **Registering a new parent** takes `sudo morzer config set registration=true` first, then `register`, then `registration=false` again. Registrations already made keep working.

```sh
sudo morzer update --stage
sudo morzer update --to 0.18.0
```

### Security

- **acme-dns takes no new registrations by default**, as anyone reaching its port 443 could register. To register a parent, `sudo morzer config set registration=true`, run `register`, then set it back to `false`; `register` says so. Existing registrations keep working.
