# acme-dns reference

The `dotdash-acme-dns` bundle (`ghcr.io/morzecrew/dotdash-acme-dns`) is an
[acme-dns](https://github.com/joohoi/acme-dns) server. It answers the
DNS-01 checks of the wildcard certificates servers and relays take under
`cert_issuer=acme-dns`. Setting it up, and a server or relay on it, is in
[Certificates](server/certificates.md#an-acme-dns-server).

Install it with `--domain`, the zone it answers for, such as
`auth.example.org`: a name under a domain apart from the servers' and the
relays'.

## Parameters

Set one with `sudo morzer config set <name>=<value>`.

| Name | Default | |
| --- | --- | --- |
| `address` | none, given at `init` | the machine's public IPv4 address: the zone answers it for its own name, and ports 53 and 443 are published on it alone, apart from a local resolver's `127.0.0.53:53`. It must be on the machine's own interface (`ip -4 addr`) |
| `nameserver` | none, given at `init` | the name the zone's `NS` record at your DNS host points to, such as `acme-ns.example.org`, with an `A` record for `address` there; outside the zone, so the delegation needs no glue record |
| `api_tls` | `letsencrypt` | `letsencrypt`: the API on 443 under a certificate acme-dns takes for the zone's name through its own DNS; `none`: plain HTTP on 443, for a test machine only |
| `registration` | `false` | `true`: the API takes new registrations. Turn it on only while you run `register`, then off again. Registrations already made keep working either way |

## Registering a parent

Each parent a wildcard is over, such as `s.example.net` for
`*.s.example.net`, registers once:

```sh
sudo morzer config set registration=true
sudo morzer task run register --output -- s.example.net
sudo morzer config set registration=false
```

`register` prints the `CNAME` for the parent's DNS host and the `acme_dns`
secret for each machine under it
([Certificates](server/certificates.md#setting-it-up)). With
`registration=false` it says to turn registration on, and does nothing.
Registration is off by default, as anyone who reaches port 443 could
otherwise register, each time costing a password hash and a row on a small
machine.

## One install for servers, another for relays

Each parent's `_acme-challenge` `CNAME` is public and names the zone it
points into. With the servers' and the relays' parents in one zone, anyone
who reads both records sees that they belong together, even with the
[parents kept apart](server/certificates.md#separate-parents-for-servers-and-relays).
To keep relays from pointing at the servers, give each side its own
install, with its own zone under its own domain, on its own machine.

## Tasks

| Task | |
| --- | --- |
| `register --output -- <parent>` | registers a parent, with `registration=true`: prints its `CNAME` and the `acme_dns` secret of every machine under it |

## Health

`doctor` and each `apply` pass while the zone answers over DNS and the API
over HTTPS under its certificate. Before the first certificate, `apply`
waits for the `NS` record to delegate the zone here.

Its registrations are in its data volume, which morzer's backups hold. Lose
them and every parent registers again, with a new `CNAME` and a new secret
on each machine.
