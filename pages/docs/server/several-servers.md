# Several servers

Same keys on every server, each under its own domain, and the same profiles
and transport parameters. Links then cover every server, and the Xray config
fails over between them. Add and revoke devices on each.

```sh
# on the first server; sudo on b.example.com must not prompt
for s in vless_clients vless_seed reality_key reality_short_id xhttp_path kcp_seed subscription_key; do
  sudo cat /run/dotdash/secrets/$s | ssh b.example.com sudo morzer secret set $s
done
# on every server
sudo morzer config set servers=example.com,b.example.com
```

- **The same profiles and transport parameters.** Each server prints every
  server's links and outbounds with its own settings: `https_port` (or
  `entry_port`), and the `xhttp-reality`, `mkcp` and `hysteria2` profiles
  with `xhttp_reality_port`, `kcp_port`, `kcp_header`, `kcp_open` and
  `hysteria2_port`. Where one server runs mKCP and another doesn't, or on
  another port, the first one's devices get dead links to the other.
- **`kcp_seed`:** every server's mKCP links carry this server's seed, so
  with another seed there they are dead.
- **`subscription_key`:** a device's URL is the same token on every server.
  A relay fetches it from the first server that answers, so with another
  key there the URL gets a 404.
- While [rotating the REALITY key](secrets.md#rotating-the-reality-key),
  copy `reality_key_second` and `reality_short_id_second` too.
