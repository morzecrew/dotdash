# Share the proxy port

The proxy port, 7890, is SOCKS5 and HTTP on one port. At first it listens on
`127.0.0.1`, for this machine alone, and asks for nothing. To let other
devices on the LAN use it, publish it on an address they can reach. Devices
then have to give a username and a password: `dotdash` and the generated
`proxy_password` secret.

!!! note
    `192.168.1.10` below stands for this machine's LAN address: use yours.

1. **Find this machine's LAN address**, the one devices reach it at:

    ```sh
    hostname -I     # this machine's addresses, such as 192.168.1.10
    ```

2. **Publish the port** on that address:

    ```sh
    sudo morzer config set listen=192.168.1.10
    ```

    Or on every address of this machine with `listen=0.0.0.0`, which keeps
    working if the address changes but also publishes the port on any other
    network the machine is on. Allow 7890/tcp from the LAN if the machine has
    a firewall.

3. **Print the settings** devices need:

    ```sh
    sudo morzer task run proxy-config --output
    ```

    ```text
    For devices on the network (as secret as a password):
    socks5h://dotdash:<password>@192.168.1.10:7890
    http://dotdash:<password>@192.168.1.10:7890

    Or, for an app that asks for them apart: server 192.168.1.10, port 7890,
    username dotdash, password <password>.
    ```

    With `listen=0.0.0.0` the task can't tell which address devices use, so
    give it after `--`: `proxy-config --output -- 192.168.1.10`.

A new password, which every device then needs:

```sh
sudo morzer secret rotate proxy_password
sudo morzer task run proxy-config --output
```

Back to this machine alone: `sudo morzer config unset listen`.

Beyond `127.0.0.1` the password can't be turned off: an open proxy on a LAN
serves whoever else gets on it.
