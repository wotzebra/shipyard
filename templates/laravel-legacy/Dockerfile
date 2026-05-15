FROM php:{{PHP_VERSION}}-fpm

# Legacy PHP base images ship Debian releases (jessie/stretch/buster) that
# have moved to archive.debian.org and whose signing keys have expired.
# Detect the codename (Debian 9 has no VERSION_CODENAME — fall back via
# VERSION_ID), rewrite sources for EOL releases, and allow unsigned/expired
# repos. The Python 2 package name varies across releases: stretch calls it
# `python`; buster+ uses `python2`. node-gyp 3.x looks for both `python` and
# `python2` on PATH, so symlink whichever is missing.
RUN set -eux; \
    . /etc/os-release; \
    CODENAME="${VERSION_CODENAME:-}"; \
    if [ -z "$CODENAME" ]; then \
        case "${VERSION_ID:-}" in \
            8)  CODENAME=jessie ;; \
            9)  CODENAME=stretch ;; \
            10) CODENAME=buster ;; \
        esac; \
    fi; \
    case "$CODENAME" in \
        jessie|stretch|buster) \
            echo "deb http://archive.debian.org/debian/ $CODENAME main"            >  /etc/apt/sources.list; \
            echo "deb http://archive.debian.org/debian-security/ $CODENAME/updates main" >> /etc/apt/sources.list; \
            { \
                echo 'Acquire::Check-Valid-Until "false";'; \
                echo 'Acquire::AllowInsecureRepositories "true";'; \
                echo 'Acquire::AllowDowngradeToInsecureRepositories "true";'; \
            } > /etc/apt/apt.conf.d/99shipyard-archive; \
            ;; \
    esac; \
    case "$CODENAME" in \
        jessie|stretch) PY_PKG=python ;; \
        *)              PY_PKG=python2 ;; \
    esac; \
    apt-get update; \
    apt-get install -y --no-install-recommends --allow-unauthenticated \
        git unzip curl ca-certificates make g++ openssh-client "$PY_PKG"; \
    command -v python2 >/dev/null || ln -sf "$(command -v python)"  /usr/local/bin/python2; \
    command -v python  >/dev/null || ln -sf "$(command -v python2)" /usr/local/bin/python; \
    rm -rf /var/lib/apt/lists/*

# Preload github.com host keys so `git clone git@github.com:...` (via npm
# `git+ssh:` deps or `git submodule update`) doesn't prompt for host-key
# verification. The SSH agent itself is forwarded from the host via
# docker-compose so the user's keys never enter the image.
RUN mkdir -p /root/.ssh \
    && chmod 700 /root/.ssh \
    && ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null \
    && chmod 600 /root/.ssh/known_hosts

ADD https://github.com/mlocati/docker-php-extension-installer/releases/latest/download/install-php-extensions /usr/local/bin/
RUN chmod +x /usr/local/bin/install-php-extensions \
    && install-php-extensions \
        pdo_mysql \
        mbstring \
        tokenizer \
        xml \
        ctype \
        bcmath \
        opcache \
        zip \
        gd \
        intl \
        exif \
        pcntl

# nvm + node so `docker compose exec php npm …` works for front-end builds.
# Version comes from the project's .nvmrc — edit that file + rebuild to bump.
ENV NVM_DIR=/usr/local/nvm
COPY .nvmrc /tmp/.nvmrc
RUN mkdir -p "$NVM_DIR" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && NODE_VERSION="$(tr -d ' \t\r\n' < /tmp/.nvmrc)" \
    && nvm install "$NODE_VERSION" \
    && nvm alias default "$NODE_VERSION" \
    && NODE_BIN_DIR="$(dirname "$(nvm which "$NODE_VERSION")")" \
    && ln -sf "$NODE_BIN_DIR/node" /usr/local/bin/node \
    && ln -sf "$NODE_BIN_DIR/npm"  /usr/local/bin/npm \
    && ln -sf "$NODE_BIN_DIR/npx"  /usr/local/bin/npx \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"' > /etc/profile.d/nvm.sh \
    && rm -f /tmp/.nvmrc

WORKDIR /var/www/html
