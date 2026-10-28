#!/bin/sh
# Download + unpack Nextcloud apps into the image at build time (no DB needed).
#
# Apps installed this way land in /usr/src/nextcloud/custom_apps; the official image entrypoint
# copies /usr/src/nextcloud -> /var/www/html on first start, so every (ephemeral) pod ships with
# the same apps. They are NOT enabled here — that is a one-off occ step in the migration Job /
# the per-pod hook, which needs the DB.
#
# Only list NON-shipped appstore apps here. Apps that Nextcloud Server bundles (e.g.
# twofactor_totp, shipped since NC25) are already in the base image and must NOT be baked again,
# or the pod would have a duplicate copy.
#
# We resolve each app's release for the base image's Nextcloud MAJOR from the appstore. An app
# with no release for this major is SKIPPED with a warning (not force-shipped) — an incompatible
# app should be left out, not baked. Versions are compared as real semver and pre-releases are
# ignored. Best-effort per app: a skip warns but does not fail the build. Review the build logs.
#
# Two forms are accepted per app id:
#   <id>            resolve the highest stable release for this NC major from the appstore.
#   <id>@<url>      download this exact tarball, bypassing the appstore. Use this for apps that
#                   have NO appstore release for the current major but DO ship a compatible built
#                   release tarball elsewhere (e.g. github.com/<org>/<app>/.../<app>.tar.gz).
#                   A pinned URL is required because there is no catalog to resolve from. Only use
#                   it for a tarball that is actually compatible with the base image's NC major —
#                   baking an older-major build (e.g. tasks 0.17.1, max-version 33) onto NC34 just
#                   produces a disabled app, since occ refuses to enable an incompatible app.
#
# Do NOT list apps that Nextcloud Server BUNDLES (shipped apps live in the base image already and
# would be duplicated). As of NC34 this includes e.g. circles (Teams) — it is shipped, so it must
# not appear here even though it is not in the appstore platform catalog.
set -eu

APPS="$*"
[ -n "${APPS}" ] || { echo "install-apps: no apps requested, nothing to do"; exit 0; }

CUSTOM_APPS=/usr/src/nextcloud/custom_apps
mkdir -p "${CUSTOM_APPS}"

baked=""
skipped=""

# Major version of the base image (e.g. 34) — used to pick a compatible app release.
NC_MAJOR="$(php -r 'require "/usr/src/nextcloud/version.php"; echo explode(".", implode(".", $OC_Version))[0];' 2>/dev/null || echo "")"
[ -n "${NC_MAJOR}" ] || NC_MAJOR="$(. /usr/src/nextcloud/version.php 2>/dev/null; echo "${OC_VersionString%%.*}")"
echo "install-apps: target Nextcloud major = ${NC_MAJOR:-unknown}"

API="https://apps.nextcloud.com/api/v1/platform/${NC_MAJOR}.0.0/apps.json"
CATALOG="$(mktemp)"
echo "install-apps: fetching catalog ${API}"
curl -fsSL "${API}" -o "${CATALOG}"

for entry in ${APPS}; do
  # Split optional pinned-url form "id@url".
  case "${entry}" in
    *@*) app="${entry%%@*}"; url="${entry#*@}";;
    *)   app="${entry}";     url="";;
  esac
  echo "install-apps: ${app}"

  if [ -z "${url}" ]; then
    # Highest STABLE release's download url for this major (semver compare, skip pre-releases).
    url="$(jq -r --arg id "${app}" '
        [ .[] | select(.id == $id) ] | (.[0].releases // [])
        | map(select(.version | test("-(rc|beta|alpha)|nightly"; "i") | not))
        | sort_by(.version | split(".") | map(tonumber? // 0))
        | (last // {}) | .download // empty
      ' "${CATALOG}")"
  else
    echo "install-apps: ${app} uses a pinned url (appstore catalog bypassed)"
  fi

  if [ -z "${url}" ]; then
    echo "install-apps: WARNING ${app} has no NC${NC_MAJOR} release in the appstore — skipping"
    echo "install-apps:   (if ${app} is needed, either it is shipped with the server already, or"
    echo "install-apps:    pass it as '${app}@<tarball-url>' to bake a specific built release)"
    skipped="${skipped} ${app}"
    continue
  fi
  tmp="$(mktemp -d)"
  curl -fsSL "${url}" -o "${tmp}/app.tar.gz"
  tar -xzf "${tmp}/app.tar.gz" -C "${CUSTOM_APPS}"
  # Sanity: the tarball must unpack to a dir named after the app id, else the app won't load.
  [ -d "${CUSTOM_APPS}/${app}" ] || { echo "install-apps: ERROR ${app} did not unpack to ${CUSTOM_APPS}/${app}"; exit 1; }
  rm -rf "${tmp}"
  echo "install-apps: ${app} -> ${url}"
  baked="${baked} ${app}"
done

rm -f "${CATALOG}"
chown -R www-data:www-data "${CUSTOM_APPS}"
echo "install-apps: baked:${baked:-' (none)'}"
[ -z "${skipped}" ] || echo "install-apps: skipped (not in appstore, no pinned url):${skipped}"
echo "install-apps: done"
