# Relay

A third bundle (`ghcr.io/morzecrew/dotdash-relay`, released with dotdash) for a
machine inside the country, for networks that let only domestic addresses
through, as mobile networks do during shutdowns. Devices connect to the relay
on 443 under the name of a site next to it, and the relay carries them on to
this server as one client of its own. Nothing leaves the relay except to
dotdash. It also helps where TLS to foreign hosting is slowed down. Needs
Docker, sops, age and morzer (`bootstrap.sh`), and port 443.

The relay only helps if its address gets through. Whether one does depends on
the network, the provider and the day: test it from a SIM on such a network.
On those networks only 443 and TCP get through, so the DNS tunnel is no use
there.

1. On the server, add a `<uuid> relay` line to `vless_clients`, then run what
   this prints on the relay machine. It ends with `relay-entry`, which prints
   one line:

    ```sh
    sudo morzer task run relay-config --output -- relay
    ```

    For `site`, pick a site in the relay's own network that speaks TLS 1.3 and
    HTTP/2, not a big name. `xray tls ping <site>` shows whether it does.
    Devices send its name, and anyone probing the relay gets its handshake.

2. On the server, add that line to the `relays` secret, one line per relay
   (the generated placeholder can go):

    ```sh
    sudo morzer secret edit relays
    ```

    `client-config` then prints a link per relay, `[relay <host>]`, and the
    Xray config falls back to the relays. Subscriptions pick them up by
    themselves. Devices need the links before a shutdown: an app can't refresh
    a subscription from this server's site while only domestic addresses get
    through.

A device added to or deleted from `vless_clients` has to change on the relay
too: `relay-config` prints the relay's copy. The relay takes one server; with
[several servers](several-servers.md), point it at the nearest. A
[canary](canary.md) inside the country checks a relay as it checks the server:
`relay-entry` prints how.

The official sing-box apps, Karing and NekoBox can't connect to dotdash at
all, relay or not: they lack VLESS Encryption and the key share REALITY now
requires.
