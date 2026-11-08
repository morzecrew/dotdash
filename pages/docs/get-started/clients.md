# Clients

```sh
sudo morzer task run client-config --output             # every device
sudo morzer task run client-config --output -- phone    # one
```

Per device: a REALITY link and an XHTTP link (`phone [reality]`,
`phone [xhttp]`), and an Xray config for v2rayN or v2rayNG (custom config)
that uses whichever answers fastest, drops a dead one within about 30 s, and
falls back to the [DNS tunnel](../options/dns-tunnel.md) when it is on.

!!! warning "The output is a password"
    Anyone holding a device's links can use the server as that device.

As QR codes in the terminal (`qrencode`):

```sh
sudo morzer task run client-config --output -- phone | grep '^vless://' |
  while read -r link; do qrencode -t ansiutf8 "$link"; done
```

How each app handles DNS: [DNS on devices](../operations/device-dns.md).

## Devices

One `<uuid> [name]` line each (`uuidgen` makes an id). Delete a line to
revoke; Xray restarts on save.

```sh
sudo EDITOR=nano morzer secret edit vless_clients
```

A revoked device still knows the shared keys. To hide the server from it too,
`sudo morzer secret rotate reality_key` and `vless_seed`, then resend links.

## Subscriptions

```sh
sudo morzer config set subscription=true
sudo morzer task run client-config --output -- phone           # its URL only
sudo morzer task run client-config --output -- --full phone    # plus links and Xray config
```

- Add the URL as a subscription in the app (v2rayN, v2rayNG, Hiddify, Happ,
  Streisand) and refresh every few hours: revocations and key rotations reach
  devices with nothing to resend.
- A URL is as secret as the links. `sudo morzer secret rotate subscription_key`
  moves every URL; any other path gets the site's 404.
