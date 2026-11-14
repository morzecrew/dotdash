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
2. **Registration,** once per parent, on the
   [acme-dns server](#an-acme-dns-server):

    ```sh
    sudo morzer task run register --output -- s.example.net
    ```

    It prints the CNAME for step 3 and the `acme_dns` secret for step 4. Keep
    the secret as you keep the servers' keys: every machine under the parent
    shares it.

3. **The CNAME,** once per parent, at your DNS host, as `register` printed it:

    ```text
    _acme-challenge.s.example.net.  CNAME  <uuid>.auth.example.org.
    ```

4. **Each machine under that parent:** the secret, then the issuer:

    ```sh
    sudo morzer secret set acme_dns       # the line register printed, then Ctrl-D
    sudo morzer config set cert_issuer=acme-dns
    ```

    Caddy takes `*.s.example.net` over DNS-01 and serves it for the machine's
    name. On a relay it takes the same steps, under the `own-site` profile.
    On a new machine, give `init` `--set cert_issuer=acme-dns` and set the
    secret before the first `apply`: a single `apply` under `acme` puts the
    machine's name in the logs.

- A domain with two labels, such as `example.net`, has no parent to take a
  wildcard over. Caddy takes a certificate in its own name, over DNS-01.
- A name already in the logs stays there. To keep a machine out, move it to a
  new name under the wildcard.
- Port 80 stays open, for the redirect to HTTPS.
- If the registration is missing or malformed, Caddy doesn't start, and
  `doctor` fails the cover-site check. If the CNAME is wrong, Caddy starts but
  gets no certificate, and its log says why:
  `sudo docker compose -p dotdash logs caddy`.

## An acme-dns server

Run your own: whoever runs an acme-dns server can answer your domains'
checks, and the public one is meant only for testing. The
`dotdash-acme-dns` bundle is one, installed with morzer like the others.

Give it a machine of its own: the NS record that delegates its zone makes its
address public, so not a dotdash server or relay, nor the manager's machine.
Its zone goes under a domain apart from the servers' and the relays', such as
`auth.example.org`: every domain it serves points a public CNAME into that
zone, and one under the servers' domain would name it from the relays'.

1. **Firewall:** open 53/udp, 53/tcp and 443/tcp in the provider's firewall.
   Install Docker and morzer as on [every machine](../index.md#what-every-machine-needs).
2. **DNS,** at `example.org`'s DNS host, before the first `apply`:

    ```text
    acme-ns.example.org.  A   <its IP>
    auth.example.org.     NS  acme-ns.example.org.
    ```

    The nameserver is outside the zone it serves, so the delegation needs no
    glue record, which some DNS hosts can't make.

3. **Install:**

    ```sh
    sudo morzer init --release oci://ghcr.io/morzecrew/dotdash-acme-dns:stable \
      --domain auth.example.org --recovery-recipient age1… \
      --set address=<its IP> --set nameserver=acme-ns.example.org
    sudo morzer apply
    ```

    `address` must be on the machine's own interface (`ip -4 addr`): ports 53
    and 443 are published on it alone, apart from a local resolver on
    `127.0.0.53`. `apply` waits for the API's certificate, which acme-dns takes
    for `auth.example.org` through its own DNS, so it succeeds only once the
    NS record above resolves.

4. **Register** each parent, as in step 2 [above](#setting-it-up).

Its registrations are in its data volume, which morzer's backups hold. Lose
them and every parent registers again, with a new CNAME and a new secret on
each machine.
