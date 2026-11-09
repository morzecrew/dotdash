# Client bundle

A fourth bundle (`ghcr.io/morzecrew/dotdash-client`, released with dotdash) for
a Linux machine on the client side: a home server, a Raspberry Pi, an office
VM. It runs mihomo with one SOCKS5 and HTTP proxy port that goes out through
dotdash, over whichever link of one device's subscription answers fastest.
Needs Docker, sops, age and morzer (`bootstrap.sh`).

1. On the server, with [subscriptions](../get-started/clients.md) on, add a
   `<uuid> home` line to `vless_clients` and print its URL:

    ```sh
    sudo morzer task run client-config --output -- home
    ```

2. On the client machine (the signing key is the dotdash repository's
   `MINISIGN_RELEASE_PUBKEY` variable, as for dotdash itself):

    ```sh
    sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-client:stable \
      --require-signature --signing-key "$MINISIGN_RELEASE_PUBKEY" --recovery-recipient age1…
    sudo morzer secret set subscription_url    # the URL from step 1
    sudo morzer apply
    curl --proxy socks5h://127.0.0.1:7890 https://www.gstatic.com/generate_204 -w '%{http_code}\n'
    ```

The port is on 127.0.0.1 alone. For the network, publish it there; devices
then have to give a username and password, which `proxy-config` prints as
ready proxy URLs:

```sh
sudo morzer config set listen=0.0.0.0     # or one address of this machine
sudo morzer task run proxy-config --output -- 192.168.1.10
sudo morzer secret rotate proxy_password  # a new password; run proxy-config again
```

Rules are mihomo's classical rules without the target, one per line, `#`
for comments. `block_rules` refuses, `direct_rules` goes around dotdash, and
everything else goes through it:

```sh
sudo morzer secret edit direct_rules
```

```text
DOMAIN-SUFFIX,example.ru
IP-CIDR,192.168.0.0/16,no-resolve
```

Give IP rules `no-resolve`: otherwise mihomo looks up every name on this
machine's resolver to match them, which tells that resolver what goes through
dotdash. The subscription refreshes through dotdash, so it stays current
where only dotdash gets through, such as through a [relay](relay.md) while
only domestic addresses do; directly when that fails, as on a first start.
It is cached, so a restart while the URL can't be reached starts on the links
it fetched last. Relays in the subscription are links like the others.
