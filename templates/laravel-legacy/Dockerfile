FROM php:{{PHP_VERSION}}-fpm

# Legacy PHP base images ship Debian releases (jessie/stretch/buster) that
# have moved to archive.debian.org. Rewrite sources before the first apt-get
# so the build works on EOL distros too.
RUN set -eux; \
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"; \
    case "$CODENAME" in \
        jessie|stretch|buster) \
            echo "deb http://archive.debian.org/debian/ $CODENAME main"            >  /etc/apt/sources.list; \
            echo "deb http://archive.debian.org/debian-security/ $CODENAME/updates main" >> /etc/apt/sources.list; \
            echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
            ;; \
    esac

RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        unzip \
        curl \
        ca-certificates \
        python2 \
        make \
        g++ \
    && rm -rf /var/lib/apt/lists/*

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
