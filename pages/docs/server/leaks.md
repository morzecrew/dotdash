# What leaks where

- Traffic leaves only through the upstream. With the upstream down, clients
  get nothing, never this server's address, unless `upstreams` holds a
  [`direct` line](upstreams.md#no-upstream-this-servers-own-address), which
  makes this server's address an exit on purpose. Xray has no route out; a gate
  container holds the upstream's credentials. Every apply, update and `doctor`
  checks this against what runs.
- The upstream sees destination addresses, ports and volume, not hostnames:
  this server resolves them over DoH (`dns_resolver`), through the upstream.
  SNI stays visible unless the client uses [ECH](cdn.md#ech).
  `resolve=upstream` hands the upstream the hostnames.
- On the device, only the app keeps traffic inside a dropped tunnel (TUN with
  a kill switch, or Android's "block connections without VPN"). A browser IP
  checker showing an IPv6 address that `exit-check` calls unavailable sees the
  device's own: route IPv6 into the tunnel or turn it off in the app.
- To keep IPv6 out altogether, set `ipv6=block` where it applies: on a
  [client](../client/reference.md) it is refused on the machine, on a
  [relay](../relay/reference.md) it ends there, and here no IPv6 destination
  leaves ([parameters](parameters.md)).

## WebRTC

A browser's WebRTC asks a STUN server, over UDP, which address it sees, and a
page can read the answer (the server-reflexive candidate). What it gets
depends on how the device reaches dotdash (dotdash-lab #52 measured each):

| The device | The server carries UDP (`upstream_udp`) | WebRTC's address |
| --- | --- | --- |
| A browser set to a proxy port (dotdash-client's, or an app's) | either | the device's own: STUN leaves around the proxy |
| The same, with the `WebRtcIPHandling` policy below | either | none, and no candidate at all |
| Behind a TUN (dotdash-client's `tun`, an app in VPN mode) | yes | the exit's, as the rest of its traffic |
| Behind a TUN | no (the default) | none: only a local candidate |

- **On a proxy port**, set Chromium's `WebRtcIPHandling` policy to
  `disable_non_proxied_udp`, or better, use the TUN. The policy stops the
  leak but leaves a browser with no WebRTC address at all, which a page can
  notice. Chromium's old `--force-webrtc-ip-handling-policy` switch is gone:
  the policy goes in a managed policy file (on Linux,
  `/etc/chromium/policies/managed/` or `/etc/opt/chrome/policies/managed/`):

    ```json
    {"WebRtcIPHandling": "disable_non_proxied_udp"}
    ```

- **Behind a TUN**, nothing leaks. With `upstream_udp=true` (every upstream
  line then has to carry UDP), WebRTC's address is the exit's. Without it,
  WebRTC has no public address, a smaller tell than a leaked one.
- A [canary](../canary/index.md) reports per transport whether the server
  carries UDP (`udp` in its `facts`).
- **DNS** stays inside in both modes: browsers send names to a SOCKS proxy,
  and dotdash-client's TUN answers port 53 itself.

## The browser's location

dotdash keeps the network consistent: sites see the exit IP, and geolocation
by IP follows it. The browser can still tell another story. JavaScript's
timezone (`Date`, `Intl`) and the Geolocation API read the device's own
settings, not the exit. To match them to the exit without changing the
device's settings, use a browser extension that sets both:

- **Cloaq**, for desktop Chromium. It sets them through Chrome's debugger API
  (`Emulation.setTimezoneOverride` and `setGeolocationOverride`), in the
  engine, so a page finds no JavaScript wrapper to detect:
  [Chrome Web Store](https://chromewebstore.google.com/detail/cloaq-location-guard-loca/fcalilbnpkfikdppppppchmkdipibalb).
- **GeoSpoof**, to match the exit's region in one click (VPN Sync), or on
  mobile:
    - [Chrome Web Store](https://chromewebstore.google.com/detail/geospoof-spoof-geolocatio/dgdbdodafgaeifgajaajohkjjgobcgje),
      for desktop Chromium;
    - [Firefox Add-ons](https://addons.mozilla.org/firefox/addon/geo-spoof/),
      for desktop Firefox and Firefox for Android 140 and later;
    - [App Store](https://apps.apple.com/app/geospoof-location-changer/id6765719745),
      for Safari on iOS, iPadOS and macOS.

Neither needs the proxy's credentials: they read the exit IP, or take a
region. Both are optional. Neither stops WebRTC from showing the device's
own addresses, which is a browser setting of its own.

Chrome on Android takes no extensions, so use Firefox for Android there.
GeoSpoof's [Google Play app](https://play.google.com/store/apps/details?id=com.bugsmirror.android.gpsspoofer)
is a different thing: it fakes the device's GPS for every app, as its
"Mock location app" in Developer options, rather than working in the browser.
