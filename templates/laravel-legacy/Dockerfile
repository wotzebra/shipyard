FROM php:{{PHP_VERSION}}-fpm

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
