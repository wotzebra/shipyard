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

WORKDIR /var/www/html
