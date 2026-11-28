# dotdash-manager

Runs a dotdash network from one roster through morzer's desired state: server
groups, each with its own keys, devices and exit, and the relays that carry
each device to its own group. How to set it up and use it, groups included:
[pages/docs/manager.md](../pages/docs/manager.md#server-groups).

```sh
uv run --locked pytest          # the tests
uv run dotdash-manager --help
```
