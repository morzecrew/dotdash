# Rules

Everything goes through dotdash unless a rule says otherwise. Two parameters
hold the rules:

- `direct_rules`: destinations reached directly, around dotdash;
- `block_rules`: destinations refused.

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
