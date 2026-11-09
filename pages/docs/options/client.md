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
for comments, in two parameters: `block_rules` refuses, `direct_rules` goes
around dotdash, and everything else goes through it:

```sh
sudo morzer config edit direct_rules                    # in an editor
sudo morzer config set --set-file direct_rules=rules.txt # or from a file
```

```text
DOMAIN-SUFFIX,example.ru
IP-CIDR,192.168.0.0/16,no-resolve
```

With no links at all, as on a first start that can't fetch the subscription,
the port refuses everything but the direct rules: nothing leaves around
dotdash by accident.

Give IP rules `no-resolve`: otherwise mihomo looks up every name on this
machine's resolver to match them, which tells that resolver what goes through
dotdash. The subscription refreshes through dotdash, so it stays current
where only dotdash gets through, such as through a [relay](relay.md) while
only domestic addresses do; directly when that fails, as on a first start.
It is cached, so a restart while the URL can't be reached starts on the links
it fetched last. Relays in the subscription are links like the others.

## The whole machine: the tun profile

```sh
sudo morzer config set installation.profile=tun
sudo morzer config unset installation.profile     # back to the proxy port alone
```

Every connection on the machine then goes through dotdash with no proxy
settings, its Docker containers' and IPv6 included; the proxy port and the
rules stay as they are. DNS answers with fake addresses, and the names go to
dotdash, which resolves them; the machine's own resolver answers only for
dotdash's server names and the direct rules. With dotdash out of reach,
nothing gets out around it.

It runs mihomo as root with `NET_ADMIN` and `DAC_OVERRIDE`, on the host's
network, with `/dev/net/tun`: a TUN interface takes nothing less. The root
filesystem stays read-only. Networks this machine is directly on, such as its
LAN, stay reachable directly. The subscription and the dotdash server must be
reachable over the machine's main interface, as they normally are.

### A gateway for the LAN

Under `tun`, the machine can be its LAN's gateway: devices whose gateway is its
address go through dotdash too, with nothing to set up on them. Hand that
gateway out from the main router's DHCP, or set it on each device.

```sh
sudo morzer config set gateway=true                 # doctor checks the host for it
sudo morzer config set dns_listen=192.168.1.10:53   # this machine's LAN address, if devices use it for DNS
```

Docker sets the host's `FORWARD` policy to `DROP` on many machines, which drops
the LAN's traffic before TUN sees it (dropped, never sent around dotdash).
Two rules in Docker's `DOCKER-USER` chain let it through; `doctor` names them
while they're missing:

```sh
sudo iptables -I DOCKER-USER -o Meta -j ACCEPT
sudo iptables -I DOCKER-USER -i Meta -j ACCEPT
```

They don't outlive a reboot by themselves: add them to whatever restores the
host's firewall, or to a systemd unit that runs after `docker.service`.

The gateway handed out by DHCP is IPv4's. A main router that also advertises
IPv6 gives devices a second way out, around this machine: turn IPv6 off on the
LAN, or on the devices.
