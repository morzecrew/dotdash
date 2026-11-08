# Several servers

Same keys on every server, each under its own domain and the same
`https_port`. Links then cover every server, and the Xray config fails over
between them. Add and revoke devices on each.

```sh
# on the first server; sudo on b.example.com must not prompt
for s in vless_clients vless_seed reality_key reality_short_id xhttp_path; do
  sudo cat /run/dotdash/secrets/$s | ssh b.example.com sudo morzer secret set $s
done
# on every server
sudo morzer config set servers=example.com,b.example.com
```
