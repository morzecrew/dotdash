# Beside your own web server

A machine whose own Caddy already holds 80 and 443 for other sites can run a
dotdash server or relay too. The web server keeps both ports. It reads the
server name in each TLS ClientHello and passes the connections for dotdash's
names through to it untouched, as REALITY needs. Every other connection goes
on to its sites as before.

dotdash then publishes on loopback, on spare ports:

```sh
sudo morzer config set listen=127.0.0.1 https_port=9443 http_port=9080 entry_port=443
```

`entry_port=443` keeps devices', relays' and the canary's links on 443, the
port they reach the web server on. A relay needs no `entry_port`: devices
always dial a relay on 443. Set `listen` and `https_port`, and `http_port`
under `own-site`.

## The web server

Caddy needs the [layer4](https://github.com/mholt/caddy-l4) module, which
upstream's builds leave out. The `caddy-l4` image of
[platform-images](https://github.com/morzecrew/platform-images) has it: run
that image on the host network in place of the package, or copy its binary
out, as its README shows.

```caddyfile
{
	servers :443 {
		listener_wrappers {
			layer4 {
				@dotdash tls sni s.example.net r1.example.net
				route @dotdash {
					proxy 127.0.0.1:9443
				}
			}
			tls
		}
	}
}

# Only under cert_issuer=acme: its HTTP-01 check. acme-dns needs neither.
http://s.example.net {
	reverse_proxy 127.0.0.1:9080
}
```

A server and a relay on one machine each get their own `@matcher` and
`route`, to their own `https_port`. Under `cert_issuer=acme-dns` dotdash takes
its certificate over DNS and needs nothing from the web server's port 80.

## What changes

- The web server's restarts drop dotdash's connections too.
- dotdash sees every connection come from the web server, never the device's
  address. It keeps none either way.
- A CDN in front of the server must send its domain as the server name.
  Under a name of the CDN's own, the connection goes to the web server's
  sites instead.
- A relay's `site` must not be one of the web server's own names: the
  relay sends probes to its site, and the web server would hand them straight
  back to the relay.
- The mKCP, DNS tunnel and XHTTP with REALITY ports are the machine's own
  and don't pass through the web server.
- `listen` is one IPv4 address, `0.0.0.0` (every one) by default:
  dotdash publishes these ports on no IPv6 address.
