# What leaks where

- Traffic leaves only through the upstream. With the upstream down, clients
  get nothing, never this server's address. Xray has no route out; a gate
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
