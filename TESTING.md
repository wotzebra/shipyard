# Testing Shipyard locally

Recipes for exercising Shipyard end-to-end before tagging a release. Run these from a working copy that includes your in-flight changes.

## Layers

Shipyard has two layers to consider when testing:

1. **The script (`shipyard.sh`)** — runs from your working copy, so uncommitted edits are exercised automatically.
2. **The stack templates (`templates/…`)** — fetched at scaffold time from GitHub, pinned to the tag `v$VERSION`. Override with `SHIPYARD_TEMPLATE_REF` to point at a branch / commit SHA / unreleased tag.

```bash
# Use a feature branch's templates while iterating
export SHIPYARD_TEMPLATE_REF=feature/legacy-projects-without-sail
```

The ref must be pushed to `wotzebra/shipyard` on GitHub — Shipyard fetches via `curl` over HTTPS.

## Running the working copy

```bash
bash /path/to/shipyard/shipyard.sh init
```

Confirm `git diff` shows the edits you expect before running.

## Preset-by-preset smoke tests

Each recipe scaffolds a fixture project, runs `shipyard init`, and verifies the docker stack parses. Tear down with `docker compose down -v` afterwards.

### `sail` (existing Laravel project)

Use any Sail-enabled Laravel project. Move its `.env` aside first so the existence check passes:

```bash
cd /path/to/sail-project
mv .env .env.bak
shipyard init   # pick 1 (Sail)
docker compose config --quiet && echo "compose ok"
mv .env.bak .env   # restore
```

### `laravel-legacy`

```bash
mkdir /tmp/legacy-smoke && cd /tmp/legacy-smoke
echo '{}' > composer.json
SHIPYARD_TEMPLATE_REF=feature/legacy-projects-without-sail \
    bash /path/to/shipyard/shipyard.sh init
# Pick: 2 (laravel-legacy), PHP 7.4, MySQL 5.7, no optional services,
# no domain, no post-setup
docker compose config --quiet && echo "compose ok"
docker compose up -d
curl -I "http://localhost:$(grep APP_PORT .env | cut -d= -f2)"
docker compose down -v
```

To exercise the optional-services path, answer `y` to Meilisearch and/or Elasticsearch and provide an image tag (e.g. `latest`, `7.17.28`).

### `cakephp-2` (synthetic fixture)

The fastest cake-2 path uses a minimal fixture that mirrors the wotzebra layout — `app/Config/dev/{bootstrap,config,database,email}.php` plus a `public_html/` docroot:

```bash
mkdir -p /tmp/cake-smoke/app/Config/dev /tmp/cake-smoke/public_html
cat > /tmp/cake-smoke/app/Config/dev/database.php <<'EOF'
<?php
class DATABASE_CONFIG {
    public $default = array(
        'host' => '10.0.0.1', 'login' => 'old', 'password' => 'oldpw', 'database' => 'olddb',
    );
}
EOF
cat > /tmp/cake-smoke/app/Config/dev/bootstrap.php <<'EOF'
<?php
define('SITE_URL', 'http://old.example/');
EOF
cat > /tmp/cake-smoke/app/Config/dev/email.php <<'EOF'
<?php
class EmailConfig {
    public $default = array('host' => '10.0.0.2', 'port' => 25);
}
EOF
cat > /tmp/cake-smoke/app/Config/dev/config.php <<'EOF'
<?php
$config = array('Site' => array('url' => 'http://old.example/'));
EOF

cd /tmp/cake-smoke
SHIPYARD_TEMPLATE_REF=feature/legacy-projects-without-sail \
    bash /path/to/shipyard/shipyard.sh init
# Pick: 3 (cakephp-2), PHP 7.4, MySQL 5.7, Y to detected docroot (public_html)

# Verify patches landed where expected
grep host app/Config/docker/database.php   # → 'mysql'
grep host app/Config/docker/email.php      # → 'mailpit'
grep SITE_URL app/Config/docker/bootstrap.php  # → cake_smoke.test (PROJECT_NAME)
cat app/Config/local.php

docker compose config --quiet && echo "compose ok"
docker compose down -v 2>/dev/null
```

### `cakephp-2` against a real project (eur001)

This is the most authoritative test but it modifies the project. Two safe ways:

```bash
# Option A — throwaway clone
git clone /Users/jyrki/Sites/eur001 /tmp/eur001-smoke
cd /tmp/eur001-smoke
shipyard init   # exercise overwrite-prompt path if docker/ already exists

# Option B — stash on the real project, test, then restore
cd /Users/jyrki/Sites/eur001
git stash -u
shipyard init
# Inspect…
git clean -fdx
git stash pop
```

eur001 already ships an `app/Config/docker/` and a root `docker-compose.yml`, so an init run here exercises the **overwrite prompts**. Decline once to confirm the abort path, re-run accepting to see the actual rewrite.

## Working with a scaffolded stack

Once a project's been initialised by Shipyard, day-to-day Docker work is the same regardless of preset. The scaffolded `SHIPYARD.md` in the target project is the source of truth for that project's specific ports and credentials — these recipes are the generic patterns.

### Bring up / down

```bash
docker compose up -d                  # start in background
docker compose down                   # stop containers
docker compose down -v                # stop + wipe mysql / search volumes
docker compose logs -f php nginx      # tail web services
docker compose build php              # rebuild PHP image after Dockerfile/php.ini edits
```

### Running commands inside containers

```bash
# Open a shell
docker compose exec php bash
docker compose exec mysql bash

# One-off command (preserves PWD via -w)
docker compose exec -w /var/www/html php php -v
```

### Laravel artisan (sail / laravel-legacy)

```bash
docker compose exec -w /var/www/html php php artisan migrate
docker compose exec -w /var/www/html php php artisan tinker
```

### CakePHP 2 console (cakephp-2 preset)

Console expects the working directory to be `app/`:

```bash
docker compose exec -w /var/www/html/app php ./Console/cake schema create
docker compose exec -w /var/www/html/app php ./Console/cake Migrations.migrations migrate
docker compose exec -w /var/www/html/app php ./Console/cake Migrations.migrations migrate -p <PluginName>
```

### MySQL access

From the CLI:

```bash
# From the host (find the port in .env or SHIPYARD.md)
mysql -h 127.0.0.1 -P <FORWARD_DB_PORT> -u sail -ppassword <dbname>

# Load a SQL dump
docker compose exec -T mysql mysql -usail -ppassword <dbname> < path/to/dump.sql

# Inside the mysql container
docker compose exec mysql mysql -u root -ppassword
```

From a GUI client (TablePlus, DBeaver, Sequel Ace, …):

| Field | Value |
|---|---|
| Host / Server | `127.0.0.1` |
| Port | look it up in the project's `.env` (`FORWARD_DB_PORT=…`) or its `SHIPYARD.md` |
| User | `sail` (root: `root`) |
| Password | `password` |
| Database | the project's `COMPOSE_PROJECT_NAME` |

The container hostname `mysql:3306` only works **inside** the docker network; host-side clients always connect via `127.0.0.1:<forwarded-port>`.

### Composer (ad-hoc, not in the php image)

```bash
# Repo-root composer.json
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/var/www/html" -w /var/www/html \
    composer:2 composer require <package>

# app/composer.json (some Cake 2 layouts)
docker run --rm -u "$(id -u):$(id -g)" \
    -v "$(pwd):/var/www/html" -w /var/www/html/app \
    composer:2 composer require <package>
```

Use `composer:1` instead of `composer:2` for PHP 5.6 / 7.0 / 7.1.

### Node / npm (front-end builds)

Legacy presets bake `nvm` into the `php` image and install whichever version is pinned in the project's `.nvmrc`. Shipyard creates `.nvmrc` during init if it doesn't already exist (prompting for a version) and reads from it otherwise.

```bash
docker compose exec -w /var/www/html php npm install
docker compose exec -w /var/www/html php npm run build
docker compose exec -w /var/www/html php npx gulp
```

To change the default Node version: edit `.nvmrc`, then:

```bash
docker compose build --no-cache php
docker compose up -d --force-recreate php
```

`nvm` is sourced in login shells, so for interactive multi-version work: `docker compose exec php bash -l`, then `nvm install <version>` (resets on rebuild).

## Resetting between runs

If you re-run init in the same fixture:

- Remove scaffolded files: `git clean -fdx` (if the fixture is a git repo) or `rm -rf docker-compose.yml Dockerfile nginx.conf php.ini .env`
- For cake-2, also remove `app/Config/docker/` and `app/Config/local.php`
- Clear the registry entry: `shipyard cleanup` (or hand-edit `~/.config/shipyard/projects.conf` and remove the `[fixture_name]` block)

## Composer-detection sanity check (no Docker pull)

Source the script and stub `docker` to capture what would be invoked, without actually fetching a composer image:

```bash
WC=$(wc -l < /path/to/shipyard/shipyard.sh) && KEEP=$((WC - 8))
head -n $KEEP /path/to/shipyard/shipyard.sh > /tmp/shipyard-funcs.sh

bash <<'OUTER'
source /tmp/shipyard-funcs.sh </dev/null 2>/dev/null
docker() { echo "DOCKER: docker $*"; }
export -f docker

mkdir -p /tmp/comp-test && cd /tmp/comp-test
echo '{}' > composer.json
cat > composer.lock <<'JSON'
{ "plugin-api-version": "2.6.0", "content-hash": "abc" }
JSON

PRESET=cakephp-2 SELECTED_PHP_VERSION=5.6 run_composer_install
# Expect: composer:2 (lockfile beats the PHP-5.6 → composer:1 heuristic)
OUTER

rm -rf /tmp/comp-test /tmp/shipyard-funcs.sh
```

Useful when sanity-checking version-detection logic or auth.json placement without paying the docker-pull cost.

## Validating the YAML

`docker compose config --quiet` is the cheapest authoritative parser. If it exits 0, the file is valid; if it errors, the message points at the bad line. Bash's `bash -n shipyard.sh` covers script syntax.

Python's `yaml.safe_load` is a quick alternative that catches structural problems (duplicate keys, indentation issues) without spinning up the docker client:

```bash
python3 -c "import yaml; yaml.safe_load(open('docker-compose.yml')); print('valid')"
```

## After releasing

After tagging `v0.5.0` and pushing to GitHub:

```bash
git tag v0.5.0
git push origin v0.5.0
```

Verify the pinned templates resolve:

```bash
curl -fsSL "https://raw.githubusercontent.com/wotzebra/shipyard/v0.5.0/templates/laravel-legacy/Dockerfile" | head -3
```

If you get a 404, the tag was never pushed and installed copies of shipyard 0.5.0 will fail every template fetch.
