# The whole machine

The `tun` profile sends every connection on the machine through dotdash,
with no proxy settings: its Docker containers' and IPv6 included. The proxy
port and the [rules](rules.md) stay as they are.

```sh
sudo morzer config set installation.profile=tun
sudo morzer config unset installation.profile     # back to the proxy port alone
```

- DNS answers with fake addresses, and the names go to dotdash, which
  resolves them. `dns_server` (`1.1.1.1`), asked directly, answers only for
  dotdash's server names, the direct rules, and `.lan`, `.local` and
  `.home.arpa` names. Set it to your router's address for the LAN's own
  names, or where public resolvers don't answer:

    ```sh
    sudo morzer config set dns_server=192.168.1.1
    ```

- With dotdash out of reach, nothing gets out around it. Nor while Xray
  itself is down, after a crash or on the restart for a new subscription:
  a kill switch keeps routing rules that let only Xray's own connections and
  the LAN out then. `sudo morzer doctor` checks they are in place.
- Networks the machine is directly on, such as its LAN, stay reachable
  directly.
- The subscription and the dotdash server must be reachable over the
  machine's main interface, as they normally are. With no link that
  answers, as on a first start, the subscription's fetch alone goes
  directly, from Xray.

Xray then runs as root with `NET_ADMIN`, `DAC_OVERRIDE` and
`NET_BIND_SERVICE`, on the host's network, with `/dev/net/tun`: a TUN
interface takes nothing less. Its root filesystem stays read-only.
The kill switch runs beside it as root with `NET_ADMIN` alone. Leaving the
profile, or stopping dotdash-client, takes its rules out. If it was killed
instead and the machine reaches nothing but its LAN, take them out by hand:

```sh
sudo ip rule del pref 9001; sudo ip rule del pref 9002
sudo ip -6 rule del pref 9001; sudo ip -6 rule del pref 9002
```

## A gateway for the LAN

Under `tun`, the machine can be its LAN's gateway: devices whose gateway is
its address go through dotdash too, with nothing to set up on them.

It is a gateway beside the main router, on the same LAN: one network
interface, and the main router keeps the internet link and hands out
addresses. It doesn't replace the router. Making this machine the LAN's only
router, with two interfaces, its own DHCP server and NAT, is host setup that
dotdash leaves to you; a router system such as OpenWrt suits that better.

It carries IPv4 only. IPv6 from the LAN can't go through it, so step 4 turns
IPv6 off around it, before any device is pointed at it.

!!! note
    `192.168.1.10` below stands for this machine's LAN address
    (`hostname -I` shows it): use yours.

1. **Turn it on**, so `doctor` checks the host for it:

    ```sh
    sudo morzer config set gateway=true
    ```

2. **Let the host forward.** It must forward IPv4:

    ```sh
    echo net.ipv4.ip_forward=1 | sudo tee /etc/sysctl.d/90-dotdash-gateway.conf
    sudo sysctl --system
    ```

    Docker sets the host's `FORWARD` policy to `DROP` on many machines, which
    drops the LAN's traffic before TUN sees it (dropped, never sent around
    dotdash). Two rules in Docker's `DOCKER-USER` chain let it through:

    ```sh
    sudo iptables -I DOCKER-USER -o Meta -j ACCEPT
    sudo iptables -I DOCKER-USER -i Meta -j ACCEPT
    ```

    They don't outlive a reboot by themselves: add them to whatever restores
    the host's firewall, or to a systemd unit that runs after
    `docker.service`. `doctor` names whichever is missing.

3. **Answer the LAN's DNS**, if devices are to ask this machine:

    ```sh
    sudo morzer config set dns_listen=192.168.1.10:53
    ```

    Not `0.0.0.0:53`, which clashes with systemd-resolved's stub.

4. **Turn IPv6 off around it.** A main router that advertises IPv6 gives
   every device a second way out, straight past this machine. Turn off IPv6,
   or its router advertisements, on the main router; failing that, on each
   device. Then check on this machine:

    ```sh
    ip -6 route show default     # prints nothing once the main router stops advertising
    ```

    A line with `proto ra` there means the LAN still has IPv6 from the main
    router.

5. **Point devices at it:** hand out `192.168.1.10` as the gateway (and DNS
   server) from the main router's DHCP, or set it on each device.

6. **Check from a device:** an IP checker shows the dotdash exit, and an IPv6
   test (`curl -6 https://api6.ipify.org`) fails rather than showing the
   device's own address.
