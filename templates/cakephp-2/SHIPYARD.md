# Docker development stack

This project's Docker stack was scaffolded by [Shipyard](https://github.com/wotzebra/shipyard) (`cakephp-2` preset). Files Shipyard created or patched:

- `docker-compose.yml` — service definitions
- `Dockerfile` — PHP-FPM image based on `php:{{PHP_VERSION}}-fpm`
- `nginx.conf` — vhost serving `{{NGINX_DOCROOT}}/`
- `php.ini` — dev-friendly PHP settings (`display_errors=On`, `memory_limit=512M`, etc.)
- `.env` — port assignments managed by Shipyard
- `app/Config/docker/` — env-specific Cake config, cloned from your `dev/` and patched to talk to the Docker services
- `app/Config/local.php` — per-machine selector pointing at the new `docker/` env

## Services

| Service | Image | Host port | In-container address |
|---|---|---|---|
| `php` | built from `Dockerfile` | — | `php:9000` (FPM) |
| `nginx` | `nginx:alpine` | `{{APP_PORT}}` | `nginx:80` |
| `mysql` | `mysql:{{MYSQL_VERSION}}` | `{{FORWARD_DB_PORT}}` | `mysql:3306` |
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
docker compose down -v            # stop + wipe mysql / search volumes

# Logs
docker compose logs -f php nginx  # tail the two web services
docker compose logs --since 5m    # last 5 minutes from everything

# Rebuild after Dockerfile or php.ini changes
docker compose build php
docker compose up -d php          # restart php with the new image

# Shell into containers
docker compose exec php bash
docker compose exec mysql bash

# Run the Cake console (Shipyard auto-detected the right working directory)
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake <command>

# Examples
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake schema create
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake Migrations.migrations migrate
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake Migrations.migrations migrate -p <PluginName>
```

## First-time setup commands

Typical commands to run once after `shipyard init` succeeds and the containers are up. These are project-specific (they call into installed plugins), so check your project for the exact set — examples below cover the wotzebra-standard layout:

```bash
# Sync DB schema (Utils plugin)
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake utils.db update

# Build view caches / compiled views (System plugin)
docker compose exec -w {{CAKE_CONSOLE_WORKDIR}} php ./Console/cake system.views

# Connect to MySQL from the host (mysql CLI)
mysql -h 127.0.0.1 -P {{FORWARD_DB_PORT}} -u sail -ppassword {{PROJECT_NAME}}

# Load a SQL dump
docker compose exec -T mysql mysql -usail -ppassword {{PROJECT_NAME}} < path/to/dump.sql
```

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

Composer is not installed inside the `php` image. Use the official sidecar. If your `composer.json` lives at the repo root:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/var/www/html" -w /var/www/html \
    composer:2 composer <command>
```

If `composer.json` lives at `app/composer.json`:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/var/www/html" -w {{CAKE_CONSOLE_WORKDIR}} \
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

## Node / npm (front-end builds)

The `php` image ships with `nvm` and installs whichever Node version is pinned in this project's `.nvmrc`. `node`, `npm`, and `npx` are on `PATH` directly, so:

```bash
docker compose exec -w /var/www/html php npm install
docker compose exec -w /var/www/html php npm run dev
docker compose exec -w /var/www/html php npm run build
docker compose exec -w /var/www/html php npx gulp
```

If your `package.json` lives under `app/` instead of the project root, swap `-w /var/www/html` for `-w /var/www/html/app`.

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

## Switching CakePHP environments

`app/Config/local.php` is the per-machine selector. To switch from the Shipyard-generated `docker/` env back to `dev/` (or any other), edit:

```php
Configure::write('env', 'docker');   // ← change to dev/master/preview/etc.
```

## Credentials

- MySQL user: `sail` / password: `password`
- MySQL root password: `password`
- MySQL database name: `{{PROJECT_NAME}}` (already set in `app/Config/docker/database.php`)
- Mailpit: no auth on the UI

## Regenerating this stack

Re-running `shipyard init` will prompt before overwriting `app/Config/docker/` and `app/Config/local.php`. Removing the `[<project>]` block from `~/.config/shipyard/projects.conf` lets the port registry be re-populated cleanly.

See the [Shipyard README](https://github.com/wotzebra/shipyard) for full details.
