# XHTTP with REALITY

A third link on its own port (`xhttp_reality_port`, 8443), for a network that
passes another port better than 443. Xray-core clients only (v2rayN, v2rayNG).
Open the port in the provider's firewall, then:

```sh
sudo morzer config set installation.profile=xhttp-reality   # with the DNS tunnel: xdns-xhttp-reality
```

Off: set the previous profile (`xdns`) or
`sudo morzer config unset installation.profile`, before any rollback to a
release without it.
