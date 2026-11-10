# Client

The `dotdash-client` bundle (`ghcr.io/morzecrew/dotdash-client`) runs on a
Linux machine on the client side: a home server, a Raspberry Pi, an office
VM. It runs mihomo from one device's subscription URL and sends traffic
through dotdash, over whichever of that device's links answers fastest.

![Apps set to a proxy, the machine's own connections, and LAN devices that use it as their gateway all reach mihomo, which sends the direct rules around dotdash and everything else through it](../assets/diagrams/client.light.svg#only-light)
![Apps set to a proxy, the machine's own connections, and LAN devices that use it as their gateway all reach mihomo, which sends the direct rules around dotdash and everything else through it](../assets/diagrams/client.dark.svg#only-dark)

Three ways in, from least to most:

| | What goes through dotdash | Set up |
| --- | --- | --- |
| **Proxy port** | apps set to use a SOCKS5 or HTTP proxy, on this machine or, [shared](network.md), on the LAN | the default |
| **Whole machine** | every connection on this machine, its containers' too, with no proxy settings | the [`tun` profile](tun.md) |
| **LAN gateway** | every device whose gateway is this machine | [`tun` with `gateway=true`](tun.md#a-gateway-for-the-lan) |

[Rules](rules.md) send chosen destinations around dotdash or refuse them;
everything else goes through it. With dotdash out of reach, nothing leaves
around it.

## Install

The machine needs Docker, sops, age and morzer
([`bootstrap.sh`](../index.md#what-every-machine-needs)).

1. **On the server**, with [subscriptions](../server/devices.md#subscriptions)
   on, add a device for this machine, a `<uuid> home` line in
   `vless_clients`, and print its URL:

    ```sh
    sudo EDITOR=nano morzer secret edit vless_clients
    sudo morzer task run client-config --output -- home
    ```

2. **On the client machine:**

    ```sh
    morzer secret recipients generate-recovery-key ~/client-recovery.key   # keep it off the machine
    sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-client:stable \
      --recovery-recipient age1…
    sudo morzer secret set subscription_url    # the URL from step 1
    sudo morzer apply
    ```

3. **Check** that the port gets out through dotdash; `204` means it does:

    ```sh
    curl --proxy socks5h://127.0.0.1:7890 https://www.gstatic.com/generate_204 -w '%{http_code}\n'
    ```

The port is on `127.0.0.1`, for this machine alone. Next:
[share it with the LAN](network.md), or send the
[whole machine](tun.md) through dotdash.

## The subscription

mihomo fetches the subscription every `subscription_interval` seconds (an
hour), through dotdash, so it stays current where only dotdash gets through,
such as through a [relay](../relay/index.md) while only domestic addresses
do. When that fails, as on a first start, it fetches directly. It keeps the
last copy, so a restart while the URL is out of reach starts on the links it
fetched last. Relays in the subscription are links like the others: while
only a relay gets through, the client goes through it.
