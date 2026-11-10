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
