# Rules

Everything goes through dotdash unless a rule says otherwise. Three parameters
hold the rules, checked in this order:

- `block_rules`: destinations refused;
- `proxy_rules`: destinations sent through dotdash, even when a direct rule
  matches them too, such as one site out of a list that otherwise goes
  around dotdash;
- `direct_rules`: destinations reached directly, around dotdash.

Each holds rules in the apps' classical form without the target, one per
line, with `#` for comments:

```text
# around dotdash
DOMAIN-SUFFIX,example.net
IP-CIDR,192.168.0.0/16
```

| Rule | Matches |
| --- | --- |
| `DOMAIN,<name>` | that name alone |
| `DOMAIN-SUFFIX,<name>` | the name and every name under it |
| `DOMAIN-KEYWORD,<word>` | names that contain the word |
| `DOMAIN-REGEX,<expression>` | names the regular expression matches |
| `GEOSITE,<list>` | names on a list of Xray's geosite data, such as `category-ads-all` |
| `IP-CIDR,<range>`, `IP-CIDR6,<range>` | addresses in the range |
| `GEOIP,<list>` | addresses on a list of Xray's geoip data, such as `private` |
| `DST-PORT,<port>` | that port, or a range such as `8000-9000` |

A line of another type stops the change: `morzer` says which line.

## Other geodata

`GEOSITE` and `GEOIP` rules name lists in Xray's own `geosite.dat` and
`geoip.dat`. Lists of your choice need those files from elsewhere: give
`geosite` (or `geoip`) a URL and the file's sha256, a pinned version rather
than one that changes:

```sh
curl -sL <url> | sha256sum
sudo morzer config set geosite="<url> <sha256>"
```

The client fetches the file through dotdash once it runs, within a minute,
keeps it, and restarts on it; its log says `geosite.dat: fetched`. Only then add the
rules that name its lists: until it is there, Xray has its own file, which
lacks them, and refuses to start on such a rule. A fetched file replaces
Xray's own entirely, so every list a rule names has to be in it. Unset, the
client is back on Xray's own.

Edit them in an editor, or set them from a file:

```sh
sudo morzer config edit direct_rules
sudo morzer config set --set-file direct_rules=rules.txt
```

## IP rules match addresses, not names

An IP rule matches only an address an app gives. A name is never looked up
to match one, so this machine's resolver never learns the names that go
through dotdash. `no-resolve`, which older rules carry, changes nothing.

## When dotdash is out of reach

With no links at all, as on a first start that can't fetch the subscription,
everything but the direct rules is refused: nothing leaves around dotdash by
accident.

When every link failed its last check, as just after the server was down,
traffic takes the subscription's first link rather than waiting up to two
minutes for the next check, so the client carries traffic again as soon as
the server is back.
