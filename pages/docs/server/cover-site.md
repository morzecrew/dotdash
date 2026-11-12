# Cover site

Anyone who opens `https://example.com`, or probes 443, gets the cover site.
The bundled page differs between servers only in its title, so one server
seen reveals the others. Give each a site of its own. One parameter, `cover`,
says what serves it:

- `pages`, the default: your own files, then the bundled page;
- an app's URL: your own files, then the app.

## Your own files

Put static files in `/srv/dotdash`, readable by uid 65532. Caddy serves them
as they change, with no restart. For a path with no file, it serves the rest
of the site: the bundled page, or the app.

```sh
sudo mkdir -p /srv/dotdash
sudo cp -r ./my-site/. /srv/dotdash/
sudo chmod -R a+rX /srv/dotdash
```

To keep the files elsewhere, make `/srv/dotdash` a symlink to that directory.

## An app instead of pages

Static pages are what a probe or a provider's reviewer expects least from a
busy server. A live app, with its own routes, API answers and login wall,
looks like what it is: a site in use. Name the app in `cover`. Caddy then
passes it every request except a subscription's, XHTTP's and those for your
own files.

How Caddy reaches the app depends on where it runs:

- **A container on Caddy's network**, `dotdash_edge`, by its name. This is the
  one to prefer: the app needs no published port, and it never meets Xray,
  which is on another network.

    ```sh
    docker run -d --name cover-app --restart unless-stopped --network dotdash_edge <image>
    sudo morzer config set cover=http://cover-app:8080
    ```

    For a container that's already running, attach it instead:
    `docker network connect dotdash_edge <container>`. In a Compose file of its
    own, list `dotdash_edge` under its `networks` as `external: true`, so the
    attachment survives the app being re-created.

- **Anything published on a port of the host,** such as a container started
  with `-p 8080:8080`, as `host.docker.internal`:

    ```sh
    sudo morzer config set cover=http://host.docker.internal:8080
    ```

    The app must listen where containers can reach the host. That is all
    addresses, as `-p 8080:8080` publishes, or Docker's bridge address, as
    `-p 172.17.0.1:8080:8080` publishes. Loopback alone, `127.0.0.1`, is
    unreachable from a container. Publishing on all addresses also opens the
    port to the internet, so close it in the firewall, or publish on the
    bridge address only.

Either way:

- The app gets requests for this domain as Host, as behind any reverse proxy.
- `doctor` checks that the app answers, asking it from inside Caddy, as Caddy
  does. Any HTTP answer counts, a 401 from a login wall included. With no
  answer, visitors get a 502, so the cover-site check fails, and
  `config set cover=…` is undone when the app it names doesn't answer.
- `cover=pages` goes back to pages.

Pick something people run on servers like this one, such as a wiki, a file
share or a dashboard behind a login, and give it content. The same app on
every server would link them, as the bundled page does, so vary it.
