# DNS on devices

The Xray config from `client-config` answers port-53 DNS over DoH through the
tunnel, IPv4 only, and fails rather than asking the local network. Links leave
DNS to the app. As of November 2026:

- **v2rayNG:** import as a custom config, and keep the SOCKS port at 10808.
- **v2rayN:** TUN with a custom config needs the profile's "Socks port" at
  10808. DNS then follows v2rayN's settings, so keep them on the proxy.
- **Hiddify** drops a config's DNS and routing: use the links. Its own DNS
  goes through the proxy by default.
- **iOS:** Happ runs the config; set "Tunnel DNS" and "Include all networks".
  Check Streisand and V2Box on a DNS leak test site.
