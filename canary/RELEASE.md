# dotdash-canary 0.4.0

Released with dotdash 0.4.0.

**Before updating**, set the upstream proxy as one secret; an update without it is refused, and changes nothing:

```sh
sudo morzer secret set upstream                    # user:pass@host:port
# only with the IPv6 proxy on:
sudo morzer secret set upstream6                   # user:pass@host:port
sudo morzer config set upstream6_protocol=socks    # or http
sudo morzer update --stage
sudo morzer update --to 0.4.0
```

### Changed

- The upstream proxy is one secret, `upstream`, holding `user:pass@host:port`, so changing proxy is one restart; `upstream_host`, `upstream_port`, `upstream_username` and `upstream_password` no longer work. Run `sudo morzer secret set upstream` before updating: an update without it is refused.

- This release is never applied unattended, and `morzer rollback` from it is refused, since 0.3.x could not start without the old settings; the pre-update backup is the way back.

- The IPv6 proxy is the `upstream6` secret in the same form, turned on by `upstream6_protocol` (`socks` or `http`, now `none` by default) instead of `upstream6_host`. With it on, set `upstream6` and `upstream6_protocol` before updating, or IPv6 goes back to the first proxy.

- Links are named after the device and transport, such as `phone [reality]`, `phone [xhttp]` and `phone [xhttp+reality]`, in place of `dotdash-phone`, `dotdash-xhttp-phone` and `dotdash-xhttp-reality-phone`. Apps show the new names once the links are added again, or at the next subscription refresh.

- With subscriptions on, `client-config` prints each device's subscription URL alone, so the output stays short; `--full` before the device's name (`-- --full phone`) adds its links and Xray config, as before. With subscriptions off it prints what it always did.

- The subscription service reports healthy only once every device's subscription is written: an apply or an update waits for it, and `doctor` names the service when that never happens.
