# Stateless multi-replica Nextcloud image (Phase 2 — see docs/ha-nextcloud-stateless.md).
#
# WHY: in stateless mode every pod gets an EPHEMERAL /var/www/html (emptyDir), so apps can
# no longer be installed at runtime by the before-starting hook onto a shared PVC. Instead the
# plan's apps are BAKED into the image here (into /usr/src/nextcloud/custom_apps, which the
# official entrypoint copies into each pod's webroot on start). Enabling/config of those apps
# still happens once per deploy in the PreSync migration Job (templates/migrate-job.yaml).
#
# This image is OPT-IN: nothing uses it unless a tenant sets stateless.enabled=true and points
# stateless.image at the built tag. The default (RWO PVC, single replica) image stays the stock
# nextcloud:<tag> referenced in charts/nextcloud-tenant/values.yaml.
#
# Built + pushed by .github/workflows/build-nextcloud-tenant.yml to
# ghcr.io/dunetrails/nextcloud-tenant. To build locally instead:
#   docker build -t ghcr.io/dunetrails/nextcloud-tenant:35.0.1-all \
#     --build-arg NEXTCLOUD_TAG=35.0.1-fpm \
#     --build-arg APPS="calendar contacts notes deck forms polls collectives notify_push onlyoffice user_oidc spreed previewgenerator theming_customcss" \
#     images/nextcloud-tenant
#
# APPS lists only NON-shipped apps that the plans use (docs/plans.md). Rules:
#   - Do NOT add SHIPPED apps. Nextcloud Server bundles them into the base image, so baking would
#     duplicate the copy. Shipped on NC35 includes e.g. twofactor_totp (since NC25) and circles
#     (Teams) — circles is enabled by tenants but must NOT be listed here.
#   - An app with no appstore release for the target major can still be baked from a built tarball
#     with the pinned-url form "id@<url>" (see install-apps.sh). As of NC35 nothing needs this.
#   - tasks is not baked, by choice rather than necessity: 0.18.1 does support NC35 (it capped at
#     33 for the whole NC34 cycle, which is why it was dropped). Add "tasks" here and to the plan
#     app lists in the ApplicationSet if a plan wants it.
#
# Pin NEXTCLOUD_TAG to the SAME version as the migration Job / the version you are upgrading to.
#
# FLAVOR (apache vs fpm): this single Dockerfile builds BOTH web-tier flavors — the only
# difference is the base tag you pass. The app baking + PHP ini baking below are flavor-agnostic.
#   - fpm (default)    : NEXTCLOUD_TAG=35.0.1-fpm     -> publish e.g. :35.0.1-all-fpm-1
#   - apache (opt-in)  : NEXTCLOUD_TAG=35.0.1-apache  -> publish e.g. :35.0.1-all-1   (mod_php)
# All three tenants run the fpm flavor (docs/ha-nextcloud-fpm.md), so fpm is the default here
# and in the workflow's nextcloud_tag input; keep both in sync.
# The chart selects the flavor per tenant via stateless.webServer (apache|fpm); the fpm flavor
# adds an nginx sidecar in front of php-fpm (docs/ha-nextcloud-fpm.md). Point stateless.image at
# the tag whose flavor matches stateless.webServer.

# TEMPORARY PHP security rebuild (PHP2Shell, CVE-2026-109618/CVE-2026-109619, CVSS 9.2,
# unauthenticated RCE in PHP core — NC 35.0.1 is a confirmed in-the-wild target). The official
# nextcloud base images still ship PHP 8.5.11; the fix is 8.5.12. Until the upstream images are
# rebuilt on 8.5.12 (nextcloud/docker#2605), the php-build stage below recompiles the pinned
# patched PHP tarball ON TOP OF THE SAME BASE, reproducing the official docker-library configure
# line (the hardening flags are already in the image env as PHP_CFLAGS/PHP_CPPFLAGS/PHP_LDFLAGS).
# Only PHP changes; everything below it stays byte identical. Shared extensions compiled against
# 8.5.11 keep loading because the 8.5 extension API version is unchanged in 8.5.12.
# DROP THIS STAGE (and the two COPY --from=php-build lines + the verification RUN) as soon as
# `docker run --rm nextcloud:<tag> php -v` reports the patched version, then rebuild from the
# official base.
ARG NEXTCLOUD_TAG=35.0.1-fpm
# Patched PHP release to bake in, and its sha256 from the php.net advisory. Default: 8.5.12
# (what NC 34/35 need). The stage always runs; point both at whatever patched release matches
# the base's PHP branch.
ARG PHP_REBUILD_VERSION=8.5.12
ARG PHP_REBUILD_SHA256=08bc2eba2a588654ade1357174aa646b761556c862dda0678345ee29ed481209

FROM nextcloud:${NEXTCLOUD_TAG} AS php-build
ARG NEXTCLOUD_TAG
ARG PHP_REBUILD_VERSION
ARG PHP_REBUILD_SHA256
RUN set -eux; \
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        $PHPIZE_DEPS \
        apache2-dev \
        libargon2-dev \
        libcurl4-openssl-dev \
        libonig-dev \
        libreadline-dev \
        libsodium-dev \
        libsqlite3-dev \
        libssl-dev \
        libxml2-dev \
        zlib1g-dev \
    ; \
    curl -fsSL -o /usr/src/php.tar.xz \
      "https://www.php.net/distributions/php-${PHP_REBUILD_VERSION}.tar.xz"; \
    echo "${PHP_REBUILD_SHA256} */usr/src/php.tar.xz" | sha256sum -c -; \
    rm -f /usr/src/php.tar.xz.asc; \
    docker-php-source extract; \
    cd /usr/src/php; \
    gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)"; \
    debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)"; \
    case "${NEXTCLOUD_TAG}" in \
      *-fpm) sapiFlags='--disable-cgi --enable-fpm --with-fpm-user=www-data --with-fpm-group=www-data' ;; \
      *) sapiFlags='--disable-cgi --with-apxs2' ;; \
    esac; \
    export \
      CFLAGS="$PHP_CFLAGS" \
      CPPFLAGS="$PHP_CPPFLAGS" \
      LDFLAGS="$PHP_LDFLAGS" \
      PHP_BUILD_PROVIDER='https://github.com/docker-library/php' \
      PHP_UNAME='Linux - Docker' \
    ; \
    ./configure \
      --build="$gnuArch" \
      --sysconfdir="${PHP_INI_DIR%/php}" \
      --with-config-file-path="$PHP_INI_DIR" \
      --with-config-file-scan-dir="$PHP_INI_DIR/conf.d" \
      --enable-option-checking=fatal \
      --with-mhash \
      --with-pic \
      --enable-mbstring \
      --enable-mysqlnd \
      --with-password-argon2 \
      --with-sodium=shared \
      --with-pdo-sqlite=/usr \
      --with-sqlite3=/usr \
      --with-curl \
      --with-iconv \
      --with-openssl \
      --with-readline \
      --with-zlib \
      --disable-phpdbg \
      --with-pear \
      --with-libdir="lib/$debMultiarch" \
      $sapiFlags \
    ; \
    make -j "$(nproc)"; \
    find . -type f -name '*.a' -delete; \
    make install; \
    find /usr/local -type f -perm '/0111' -exec sh -euxc 'strip --strip-all "$@" || :' -- '{}' +; \
    cp -v php.ini-* "$PHP_INI_DIR/"; \
    php -v | grep -q "PHP ${PHP_REBUILD_VERSION} "; \
    mkdir -p /root/apache-modules; \
    if [ -f /usr/lib/apache2/modules/libphp.so ]; then \
      cp /usr/lib/apache2/modules/libphp.so /root/apache-modules/libphp.so; \
    fi

FROM nextcloud:${NEXTCLOUD_TAG}
ARG PHP_REBUILD_VERSION
# Overlay the rebuilt PHP (and the patched source tarball, so docker-php-ext-install / pecl
# build against the patched release) over the stock base. apache flavor: make install already
# wrote the new libphp.so via apxs — copying /usr/local covers the binaries; the module copy
# below is what actually swaps mod_php.
COPY --from=php-build /usr/local /usr/local
COPY --from=php-build /usr/src/php.tar.xz /usr/src/php.tar.xz
COPY --from=php-build /root/apache-modules /tmp/apache-modules
RUN set -eux; \
    if [ -f /tmp/apache-modules/libphp.so ]; then \
      cp /tmp/apache-modules/libphp.so /usr/lib/apache2/modules/libphp.so; \
    fi; \
    rm -rf /tmp/apache-modules; \
    php -v | grep -q "PHP ${PHP_REBUILD_VERSION} "

# Space-separated app ids to bake in. Keep this aligned with the tenant's plan app set
# (docs/plans.md). ExApps (app_api) are intentionally NOT included.
ARG APPS=""

COPY install-apps.sh /usr/local/bin/install-apps.sh
# Build-time source patches to baked apps (see the script header for what and why).
COPY patch-apps.sh /usr/local/bin/patch-apps.sh
# jq/curl are only needed at build time to resolve+fetch app tarballs; purge them after so the
# runtime image stays the stock image plus the baked custom_apps (no extra runtime surface).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends jq curl ca-certificates; \
    chmod +x /usr/local/bin/install-apps.sh /usr/local/bin/patch-apps.sh; \
    /usr/local/bin/install-apps.sh ${APPS}; \
    /usr/local/bin/patch-apps.sh; \
    chown -R www-data:www-data /usr/src/nextcloud/custom_apps; \
    rm -f /usr/local/bin/install-apps.sh /usr/local/bin/patch-apps.sh; \
    apt-get purge -y --auto-remove jq curl; \
    rm -rf /var/lib/apt/lists/*

# Apps now live in /usr/src/nextcloud/custom_apps and ship with every pod's webroot copy.

# Bake the PHP INI overrides into the image conf.d. WHY here (not only via the chart's
# nextcloud.phpConfigs): php-fpm reads php.ini directives from /usr/local/etc/php/conf.d just like
# apache/CLI, BUT the Helm chart mounts phpConfigs into /usr/local/etc/php-fpm.d when the nginx
# (fpm) sidecar is enabled — that dir is for FPM *pool* config, not php.ini, so an opcache/apcu
# .ini placed there is ignored. Baking into conf.d makes these apply under BOTH flavors. For the
# apache flavor the chart ALSO mounts the same-named files from nextcloud.phpConfigs on top (same
# content) — harmless. Keep in sync with charts/nextcloud-tenant/values.yaml nextcloud.phpConfigs.
#   - opcache: interned strings / accelerated files / memory bumped past the shipped defaults that
#     Nextcloud+apps exceed (clears the "interned strings buffer nearly full" admin warning).
#     max_accelerated_files raised to 32531 (next prime step) since the full app set (~58 enabled)
#     pushes past 20000 cached scripts.
#   - opcache.validate_timestamps=0: the webroot is a BAKED, IMMUTABLE emptyDir seeded from this image
#     and replaced wholesale on every deploy (new pod = new webroot), so PHP never needs to stat() each
#     include looking for edits. Turning revalidation off removes that per-request filesystem work (a
#     latency win) and makes revalidate_freq moot. TRADE-OFF: opcache will NOT notice on-disk code
#     changes without a PHP restart — which is exactly the deploy model here (pods are recreated on any
#     image change), so it is safe. Do NOT set this on a mutable/PVC webroot.
#   - apcu on CLI: memcache.local => APCu is a no-op under the CLI SAPI (cron sidecar, migrate Job,
#     preview:pre-generate CronJob) without this. JIT intentionally left off.
RUN set -eux; \
    mkdir -p /usr/local/etc/php/conf.d; \
    printf '%s\n' \
      'opcache.interned_strings_buffer=24' \
      'opcache.max_accelerated_files=32531' \
      'opcache.memory_consumption=256' \
      'opcache.revalidate_freq=60' \
      'opcache.validate_timestamps=0' \
      > /usr/local/etc/php/conf.d/zz-opcache-overrides.ini; \
    printf '%s\n' 'apc.enable_cli=1' > /usr/local/etc/php/conf.d/zz-apcu-cli.ini; \
    # Nextcloud never uses session upload progress (it does its own chunked uploads); disabling
    # it is a free hardening win recommended alongside the PHP2Shell advisory.
    printf '%s\n' 'session.upload_progress.enabled=0' \
      > /usr/local/etc/php/conf.d/zz-session-upload-progress.ini
