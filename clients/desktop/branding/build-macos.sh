#!/usr/bin/env bash
#
# Build the Gantara-branded macOS app bundle of nextcloud/desktop for one
# architecture with KDE Craft, the way upstream's mac-crafter does it
# (admin/osx/mac-crafter, Build.swift): the same blueprint repositories and
# Craft options, classic Finder sync only (no File Provider module), and no
# Sparkle (BUILD_UPDATER is off). The two architectures build on their own
# runners; build-desktop-client.yml merges them into one universal app with
# upstream's make_universal.py and only then signs, because lipo invalidates
# signatures.
#
# Prerequisites (the workflow installs these): Xcode, Python 3.12 as python3,
# and apply-branding.sh already run against <branded-desktop-src>.
#
# Usage: build-macos.sh <branded-desktop-src> <arm64|x86_64> <out-dir>
#
# <out-dir> receives app.tar (<APPLICATION_NAME>.app; tar keeps the framework
# symlinks an artifact upload would flatten) and what packaging needs from the
# build tree: the configured entitlements, the installer scripts and the
# installer artwork.

set -euo pipefail

BRANDING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="$(cd -- "${1:?usage: build-macos.sh <branded-desktop-src> <arm64|x86_64> <out-dir>}" && pwd)"
ARCH="${2:?usage: build-macos.sh <branded-desktop-src> <arm64|x86_64> <out-dir>}"
OUT="${3:?usage: build-macos.sh <branded-desktop-src> <arm64|x86_64> <out-dir>}"

# shellcheck source=branding.env
. "${BRANDING_DIR}/branding.env"

die() { printf 'build-macos: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# Craft's names for the two, as in mac-crafter's archToCraftTarget.
case "${ARCH}" in
    arm64) TARGET="macos-clang-arm64" ;;
    x86_64) TARGET="macos-64-clang" ;;
    *) die "architecture must be arm64 or x86_64, not ${ARCH}" ;;
esac
[ "$(uname -m)" = "${ARCH}" ] || die "building ${ARCH} on a $(uname -m) runner; each architecture builds natively"
grep -qF -- "---- ${APPLICATION_NAME} branding" "${DESKTOP}/NEXTCLOUD.cmake" \
    || die "${DESKTOP} is not branded; run apply-branding.sh first"

WORKSPACE="${GITHUB_WORKSPACE:-$(dirname "${DESKTOP}")}"
CRAFTMASTER="${WORKSPACE}/CraftMaster"
INI="${DESKTOP}/craftmaster.ini"
[ -f "${INI}" ] || die "craftmaster.ini missing in ${DESKTOP} (wrong desktop_ref?)"

ini_value() {
    local hits
    hits="$(grep -E "^[[:space:]]*$1[[:space:]]*=" "${INI}" | sed -E 's/^[^=]*=[[:space:]]*//; s/[[:space:]]*$//')"
    [ "$(printf '%s\n' "${hits}" | grep -c .)" -eq 1 ] || die "expected exactly one '$1' in ${INI}"
    printf '%s' "${hits}"
}
KDE_REF="$(ini_value 'craft/craft-blueprints-kde\.revision')"
NEXTCLOUD_REF="$(ini_value 'craft/craft-blueprints-nextcloud\.revision')"

# The arm64 section pins Paths/Python to the 3.12.x upstream's runners happened
# to have; point it at this runner's interpreter. -i.bak works with BSD and GNU sed.
python_prefix="$(python3 -c 'import sys; print(sys.prefix)')"
sed -i.bak -E "s#^(Paths/Python[[:space:]]*=[[:space:]]*)/Users/.*#\1${python_prefix}#" "${INI}" && rm -f "${INI}.bak"

craft() {
    python3 "${CRAFTMASTER}/CraftMaster.py" --config "${INI}" --target "${TARGET}" -c "$@"
}

step "Craft (${TARGET}) with craft-blueprints-kde@${KDE_REF}, craft-blueprints-nextcloud@${NEXTCLOUD_REF}"
[ -d "${CRAFTMASTER}" ] || git clone -q --depth=1 https://invent.kde.org/packaging/craftmaster.git "${CRAFTMASTER}"
craft --add-blueprint-repository "https://github.com/nextcloud/craft-blueprints-kde.git|${KDE_REF}|"
craft --add-blueprint-repository "https://github.com/nextcloud/craft-blueprints-nextcloud.git|${NEXTCLOUD_REF}|"
craft craft

step "Dependencies (from Nextcloud's Craft binary cache)"
craft --install-deps nextcloud-client

step "Compile ${APPLICATION_NAME}.app (${ARCH})"
craft --buildtype RelWithDebInfo --compile --install \
    --options "nextcloud-client.srcDir=${DESKTOP}" \
    --options "nextcloud-client.osxArchs=${ARCH}" \
    --options "nextcloud-client.buildTests=False" \
    --options "nextcloud-client.buildMacOSBundle=True" \
    --options "nextcloud-client.buildFileProviderModule=False" \
    --options "nextcloud-client.devMode=False" \
    --options "nextcloud-client.versionSuffix=$(printf '%s' "${APPLICATION_NAME}" | tr '[:upper:]' '[:lower:]')" \
    nextcloud-client

BUILD="${WORKSPACE}/${TARGET}/build/nextcloud-client"
APP="${BUILD}/image-RelWithDebInfo-master/${APPLICATION_NAME}.app"
CMAKE_BUILD="${BUILD}/work/build"

step "Checking the bundle"
[ -d "${APP}" ] || die "Craft produced no ${APP}"
exe="${APP}/Contents/MacOS/${APPLICATION_NAME}"
[ -x "${exe}" ] || die "no executable ${exe#"${APP}"/}"
[ "$(lipo -archs "${exe}")" = "${ARCH}" ] || die "${exe#"${APP}"/} is $(lipo -archs "${exe}"), not ${ARCH}"
[ -d "${APP}/Contents/PlugIns/FinderSyncExt.appex" ] || die "Finder extension missing from the bundle"
broker="${APP}/Contents/Library/LoginItems/${MACOS_DEVELOPMENT_TEAM}.${APPLICATION_REV_DOMAIN}.FinderSyncBroker.app"
[ -d "${broker}" ] || die "Finder broker login item missing: ${broker#"${APP}"/}"
[ ! -e "${APP}/Contents/Frameworks/Sparkle.framework" ] || die "Sparkle is in the bundle, but the updater is meant to be compiled out"
[ ! -e "${APP}/Contents/PlugIns/FileProviderExt.appex" ] || die "File Provider extension in the bundle; this build uses classic sync only"
for f in COPYING THIRD-PARTY-NOTICES.md LICENSES/LGPL-3.0-or-later.txt; do
    [ -s "${APP}/Contents/Resources/licenses/${f}" ] || die "licence file missing from the bundle: Contents/Resources/licenses/${f}"
done
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")"
[ "${bundle_id}" = "${APPLICATION_REV_DOMAIN}" ] || die "bundle identifier is ${bundle_id}, expected ${APPLICATION_REV_DOMAIN}"
if grep -i -n nextcloud "${APP}/Contents/Info.plist" | grep -v -E 'SUPublic|SUFeed|com\.nextcloud\.desktopclient'; then
    die "Info.plist names Nextcloud (lines above)"
fi
printf '    %s: %s, %s, licences in Contents/Resources/licenses\n' "${APPLICATION_NAME}.app" "${bundle_id}" "${ARCH}"

step "Staging into ${OUT}"
mkdir -p "${OUT}"
tar -C "$(dirname "${APP}")" -cf "${OUT}/app.tar" "${APPLICATION_NAME}.app"
cp "${CMAKE_BUILD}/admin/osx/macosx.entitlements" \
   "${CMAKE_BUILD}/shell_integration/MacOSX/FinderSyncExt.entitlements" \
   "${CMAKE_BUILD}/shell_integration/MacOSX/FinderSyncBroker.entitlements" \
   "${CMAKE_BUILD}/admin/osx/pre_install.sh" \
   "${CMAKE_BUILD}/admin/osx/post_install.sh" \
   "${DESKTOP}/admin/osx/installer-background.png" \
   "${DESKTOP}/admin/osx/installer-background_2x.png" \
   "${OUT}/"
grep -qF "${MACOS_DEVELOPMENT_TEAM}.${APPLICATION_REV_DOMAIN}" "${OUT}/macosx.entitlements" \
    || die "app entitlements do not claim the ${MACOS_DEVELOPMENT_TEAM}.${APPLICATION_REV_DOMAIN} app group"
ls -l "${OUT}"
