# Rules

Everything goes through dotdash unless a rule says otherwise. Two parameters
hold the rules:

- `direct_rules`: destinations reached directly, around dotdash;
- `block_rules`: destinations refused.

Each is mihomo's
[classical rules](https://wiki.metacubex.one/en/config/rules/) without the
target, one per line, with `#` for comments:

```text
# around dotdash
DOMAIN-SUFFIX,example.ru
IP-CIDR,192.168.0.0/16,no-resolve
```

Edit them in an editor, or set them from a file:

```sh
sudo morzer config edit direct_rules
sudo morzer config set --set-file direct_rules=rules.txt
```

## No resolving for IP rules

Give IP rules `no-resolve`. Without it, mihomo looks up every name on this
machine's resolver to match them, which tells that resolver every name that
goes through dotdash.

## When dotdash is out of reach

With no links at all, as on a first start that can't fetch the subscription,
everything but the direct rules is refused: nothing leaves around dotdash by
accident.
