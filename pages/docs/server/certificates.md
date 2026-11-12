# Certificates

Every certificate a public CA issues goes into the Certificate Transparency
logs, and the name in it is public from that day. Scanners read the logs for
new names, look them up and probe the address. With `cert_issuer=acme`, each
server and relay takes a certificate in its own name, so it shows up in the
logs the day it starts. With the servers kept out of devices' links
([`direct=false`](devices.md#keeping-the-servers-out-of-devices-links)), the
logs are the main place a server's name still appears.

A wildcard certificate names only the parent: `*.s.example.net` for
`x7k2.s.example.net`. The machine's own name stays out of the logs, and
nothing there points to `x7k2`.

A wildcard needs a DNS-01 check, which the CA asks of your DNS. dotdash hands
that check to an [acme-dns](https://github.com/joohoi/acme-dns) server through
one CNAME, so it works wherever your DNS is hosted. The credential each machine
holds can answer only that one check.

## Separate parents for servers and relays

Give servers and relays different parents, such as `*.s.example.net` and
`*.r.example.net` or two different domains, each with its own acme-dns
registration. Relays run on machines you trust less, and are replaced when
burnt. A relay's credential then takes certificates under the relays' parent
only, never one valid for a server's name, and a relay seen tells nothing
about where the servers are.

## Setting it up

1. **Names.** Name each machine one label under its parent, a label nobody
   would guess, such as `x7k2.s.example.net` for a server. Point it at the
   machine as usual, with an `A` record.
2. **Registration,** once per parent:

    ```sh
    curl -s -X POST https://acme-dns.example.net/register
    ```

    It answers with JSON holding `username`, `password`, `subdomain` and
    `fulldomain`. A self-hosted acme-dns server is better than a public one,
    since whoever runs the server can answer your checks. Its own address is
    public through the NS record that delegates its zone, so don't run it on a
    dotdash server or relay.

3. **The CNAME,** once per parent, at your DNS host:

    ```text
    _acme-challenge.s.example.net.  CNAME  <fulldomain>.
    ```

4. **Each machine under that parent:** the registration with the acme-dns
   server's URL added, then the issuer:

    ```sh
    printf '%s' '{"username": "…", "password": "…", "subdomain": "…", "server_url": "https://acme-dns.example.net"}' |
      sudo morzer secret set acme_dns
    sudo morzer config set cert_issuer=acme-dns
    ```

    Caddy takes `*.s.example.net` over DNS-01 and serves it for the machine's
    name. On a relay it takes the same steps, under the `own-site` profile.

- A domain with two labels, such as `example.net`, has no parent to take a
  wildcard over. Caddy takes a certificate in its own name, over DNS-01.
- A name already in the logs stays there. To keep a machine out, move it to a
  new name under the wildcard.
- Port 80 stays open, for the redirect to HTTPS.
- If the registration is missing or malformed, Caddy doesn't start, and
  `doctor` fails the cover-site check. If the CNAME is wrong, Caddy starts but
  gets no certificate, and its log says why:
  `sudo docker compose -p dotdash logs caddy`.
