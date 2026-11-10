# Set up a relay

Setting up a relay moves between three places: the dotdash server, the relay
machine, and back. The server prints everything the relay needs, and the
relay prints the one line the server needs back:

![Setup in six steps: a relay client on the server, relay-config, init and apply on the relay, relay-entry, its line into relays on the server, new links for devices](../assets/diagrams/relay-setup.light.svg#only-light)
![Setup in six steps: a relay client on the server, relay-config, init and apply on the relay, relay-entry, its line into relays on the server, new links for devices](../assets/diagrams/relay-setup.dark.svg#only-dark)

## 1. Pick the site

The relay borrows the name of a site next to it: devices send that name, and
probes get that site's handshake. Pick one that is:

- in the relay's own network, the same hosting provider or nearby, not a big
  name served from somewhere else;
- on TLS 1.3 and HTTP/2. `curl` prints `2` for one that is, and fails for one
  without TLS 1.3:

    ```sh
    curl -so /dev/null --tlsv1.3 --http2 -w '%{http_version}\n' https://site.example.ru
    ```

## 2. On the server: a client for the relay

Add a `<uuid> relay` line to `vless_clients` (`uuidgen` makes an id), then
print the relay's setup:

```sh
sudo EDITOR=nano morzer secret edit vless_clients
sudo morzer task run relay-config --output -- relay
```

!!! warning "The output is every device's credentials"
    It carries the relay's copy of `vless_clients`. Move it to the relay
    machine as you would a password.

## 3. On the relay: install

Install Docker, sops, age and morzer
([`bootstrap.sh`](../index.md#what-every-machine-needs)), and make a
recovery key as for the server:

```sh
morzer secret recipients generate-recovery-key ~/relay-recovery.key   # keep it off the machine
```

Then run what step 2 printed, with your site and the recovery key's
`age1…` filled in. It has this shape:

```sh
sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-relay:stable \
  --recovery-recipient age1… \
  --set site=site.example.ru \
  --set dotdash_servers=example.com --set dotdash_port=443 \
  --set dotdash_public_key=…
sudo morzer secret set dotdash_id <<'END'          # and dotdash_encryption,
…                                                  # dotdash_short_id,
END                                                # vless_clients
sudo morzer apply
```

`apply` succeeds once the relay gets out through dotdash. The relay
generates its own keys at `init`.

## 4. On the relay: its line

Give `relay-entry` the address devices reach the relay at, its public IP or a
name pointing at it:

```sh
sudo morzer task run relay-entry --output -- 198.51.100.7
```

It prints one line for the server, its own address, site, public key, short
id and encryption, plus the commands a [canary](../canary/index.md) needs to
check this relay:

```text
198.51.100.7 site.example.ru <public key> <short id> <encryption>
```

## 5. On the server: add the line to `relays`

One line per relay:

```sh
sudo morzer config edit relays
```

## 6. Devices

`client-config` now prints a `[relay 198.51.100.7]` link for every device,
and the Xray config falls back to the relays when the server itself is out of
reach. Subscriptions pick the link up by themselves; otherwise resend the
links. Do it now, while devices can still reach the server.

To check, connect a phone on the target network with its relay link alone.

Next: [keeping it running](operations.md).
