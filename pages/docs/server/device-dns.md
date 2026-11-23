# DNS on devices

The Xray config from `client-config` answers port-53 DNS with fake DNS: each
name gets a stand-in IPv4 address from 198.18.0.0/15 at once, and a connection
to it goes through the tunnel with the name, which the server looks up, as
dotdash-client's TUN does. Nothing is asked of the local network, and a first
visit to a name costs no round trip through the tunnel for its lookup (53 ms
less in the lab at a 50 ms round trip; more behind a relay). Links leave DNS to
the app.

Xray gives each answer a one-second lifetime, but some apps keep an address
longer: after Xray restarts, which forgets which name each stand-in address
stood for, a connection to an old one fails until the app asks for the name
again.

As of November 2026:

- **v2rayNG:** import as a custom config, and keep the SOCKS port at 10808.
- **v2rayN:** TUN with a custom config needs the profile's "Socks port" at
  10808. DNS then follows v2rayN's settings, so keep them on the proxy.
- **Hiddify** drops a config's DNS and routing: use the links. Its own DNS
  goes through the proxy by default.
- **iOS:** Happ runs the config; set "Tunnel DNS" and "Include all networks".
  Check Streisand and V2Box on a DNS leak test site.
