# Docker development stack

This project's Docker stack was scaffolded by [Shipyard](https://github.com/wotzebra/shipyard) (`laravel-legacy` preset). Files Shipyard created in this directory:

- `docker-compose.yml` — service definitions
- `Dockerfile` — PHP-FPM image based on `php:{{PHP_VERSION}}-fpm`
- `nginx.conf` — vhost serving `public/`
- `php.ini` — dev-friendly PHP settings (`display_errors=On`, `memory_limit=512M`, etc.)
- `.env` — port assignments managed by Shipyard

## Services

| Service | Image | Host port | In-container address |
|---|---|---|---|
| `php` | built from `Dockerfile` | — | `php:9000` (FPM) |
| `nginx` | `nginx:alpine` | `{{APP_PORT}}` | `nginx:80` |
| `mysql` | `mysql:{{MYSQL_VERSION}}` | `{{FORWARD_DB_PORT}}` | `mysql:3306` |
| `redis` | `redis:alpine` | `{{FORWARD_REDIS_PORT}}` | `redis:6379` |
| `mailpit` | `axllent/mailpit:latest` | `{{FORWARD_MAILPIT_PORT}}` (web UI) | `mailpit:1025` (SMTP) |

Optional services (only present if you opted in during `shipyard init`):

| Service | Image | Host port | In-container address |
|---|---|---|---|
| `meilisearch` | `getmeili/meilisearch:{{MEILISEARCH_VERSION}}` | `{{FORWARD_MEILISEARCH_PORT}}` | `meilisearch:7700` |
| `elasticsearch` | `docker.elastic.co/.../elasticsearch:{{ELASTICSEARCH_VERSION}}` | `{{FORWARD_ELASTICSEARCH_PORT}}` | `elasticsearch:9200` |

> Empty cells mean the service was not opted in; remove the row if you don't need it.

## URLs

- App: <http://localhost:{{APP_PORT}}> (replace with your `.test` domain if you registered one)
- Mailpit UI: <http://localhost:{{FORWARD_MAILPIT_PORT}}>

## Common commands

```bash
# Bring up / down
docker compose up -d              # start in background
docker compose down               # stop containers
docker compose down -v            # stop + wipe mysql / redis / search volumes

# Logs
docker compose logs -f php nginx  # tail the two web services
docker compose logs --since 5m    # last 5 minutes from everything

# Rebuild after Dockerfile or php.ini changes
docker compose build php
docker compose up -d php          # restart php with the new image

# Shell into containers
docker compose exec php bash
docker compose exec mysql bash

# Artisan
docker compose exec -w /var/www/html php php artisan <command>

# Connect to MySQL from the host (mysql CLI)
mysql -h 127.0.0.1 -P {{FORWARD_DB_PORT}} -u sail -ppassword {{PROJECT_NAME}}

# Load a SQL dump
docker compose exec -T mysql mysql -usail -ppassword {{PROJECT_NAME}} < path/to/dump.sql
```

## First-time setup after composer install

Shipyard runs `composer install --no-scripts` during init so Laravel's post-install hooks (e.g. `artisan package:discover`) don't execute under the composer sidecar's mismatched PHP version. After `docker compose up -d`, run the scripts inside your project's `php` container — it has the right PHP — once:

```bash
docker compose exec -w /var/www/html php php artisan package:discover --ansi
docker compose exec -w /var/www/html php php artisan key:generate     # if APP_KEY is empty
docker compose exec -w /var/www/html php php artisan storage:link
```

If your project lists additional post-install scripts in `composer.json`, run those the same way (e.g. `vendor:publish`, package-specific install commands).

## Connecting from a GUI client (TablePlus, DBeaver, Sequel Ace, …)

Use these values in a new MySQL connection:

| Field | Value |
|---|---|
| Host / Server | `127.0.0.1` |
| Port | `{{FORWARD_DB_PORT}}` |
| User | `sail` |
| Password | `password` |
| Database | `{{PROJECT_NAME}}` |
| Driver / Connection type | MySQL |

The mysql container is reachable inside the docker network as `mysql:3306`, but that hostname isn't resolvable from your host — always use `127.0.0.1` with the forwarded port above. Root login is `root` / `password` on the same host + port if you need it.

## Composer

Composer is not installed inside the `php` image. Use the official sidecar:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/var/www/html" -w /var/www/html \
    composer:2 composer <command>
```

Swap `composer:2` for `composer:1` on PHP 5.6 / 7.0 / 7.1.

## Private npm registries (auth tokens)

Shipyard scaffolds private npm registry credentials into `.npmrc` at init time (one scope/token per private registry — e.g. FontAwesome Pro). `.npmrc` is gitignored automatically.

The file looks like:

```ini
@fortawesome:registry=https://npm.fontawesome.com/
//npm.fontawesome.com/:_authToken=XXXXXXXXXX
```

To add a registry later (or rotate a token), append the scope mapping + the matching `//<host>/:_authToken=…` line, then re-run `npm install`.

## SSH agent forwarding (git+ssh deps, private clones)

The `php` image ships `openssh-client`, and the compose file forwards the host SSH agent into the container — so `npm` deps declared as `"foo": "git+ssh://git@github.com:org/repo.git"`, or any `git clone git@github.com:...` you run via `docker compose exec`, work without putting SSH keys into the image.

- macOS Docker Desktop bridges the host SSH agent at `/run/host-services/ssh-auth.sock` automatically; no setup needed.
- Linux: export `SHIPYARD_SSH_SOCK="$SSH_AUTH_SOCK"` before `docker compose up` so the right socket gets mounted.
- Your SSH key must be loaded in the host agent (`ssh-add -l` should list it).
- 1Password's SSH-agent integration on macOS works too — Docker Desktop's bridge follows whatever the agent socket points at.

If the npm registry-token route works for everything you need (no `git+ssh` deps in `package.json`), you can ignore this section.

## Node / npm (front-end builds)

The `php` image ships with `nvm` and installs whichever Node version is pinned in this project's `.nvmrc`. `node`, `npm`, and `npx` are on `PATH` directly, so:

```bash
docker compose exec -w /var/www/html php npm install
docker compose exec -w /var/www/html php npm run dev
docker compose exec -w /var/www/html php npm run build
docker compose exec -w /var/www/html php npx vite
```

### Changing the default Node version

Edit `.nvmrc` at the project root and rebuild the image:

```bash
echo 18 > .nvmrc                              # or any version / lts/* / etc.
docker compose build --no-cache php
docker compose up -d --force-recreate php
```

### Temporarily switching Node versions inside the container

`nvm` is sourced for login shells, so:

```bash
docker compose exec php bash -l
# inside:
nvm install 18 && nvm use 18
```

Versions installed this way are scoped to the running container and disappear on rebuild — update `.nvmrc` and rebuild if you want them to stick.

## Credentials

- MySQL user: `sail` / password: `password`
- MySQL root password: `password`
- Mailpit: no auth on the UI

## Regenerating this stack

Re-running `shipyard init` will refuse to clobber an existing `.env`; remove it (and the `[<project>]` block in `~/.config/shipyard/projects.conf`) before re-initialising. See the [Shipyard README](https://github.com/wotzebra/shipyard) for full details.
