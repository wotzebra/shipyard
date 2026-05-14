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
