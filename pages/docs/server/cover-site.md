# Cover site

Anyone who opens `https://example.com`, or probes 443, gets the cover site.
The bundled page differs between servers only in its title, so one server
seen reveals the others. Give each its own: static files in `/srv/dotdash`
(the `site_dir` parameter), readable by uid 65532. Caddy serves them as they
change, with no restart, and falls back to the bundled page for a file that
isn't there.

```sh
sudo mkdir -p /srv/dotdash
sudo cp -r ./my-site/. /srv/dotdash/
sudo chmod -R a+rX /srv/dotdash
```

## An app instead of pages

Static pages are what a probe or a provider's reviewer expects least from a
busy server. A live app, with its own routes, API answers and login wall,
looks like what it is: a site in use. Run any web app in a container on
Caddy's network and name it in `site_upstream`. Caddy then passes it every
request except a subscription's and XHTTP's, and those for files in
`site_dir`, which still win:

```sh
docker run -d --name cover-app --restart unless-stopped --network dotdash_edge <image>
sudo morzer config set site_upstream=http://cover-app:8080
```

- `dotdash_edge` is Caddy's network, the one with a way out. The app never
  meets Xray, which sits on another.
- The app gets requests for this domain as Host, as behind any reverse proxy.
- `doctor` checks that it answers. Any HTTP answer counts, a 401 from a login
  wall included. With no answer, visitors get a 502, so a stopped app fails
  the cover-site check.
- `site_upstream=none` goes back to pages.

Pick something people run on servers like this one, such as a wiki, a file
share or a dashboard behind a login, and give it content. The same app on
every server would link them as the bundled page does, so vary it.
