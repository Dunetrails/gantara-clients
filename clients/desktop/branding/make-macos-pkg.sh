#!/usr/bin/env bash
#
# Package the (signed, universal) Gantara app as a macOS installer: one .pkg that
# puts <APPLICATION_NAME>.app in /Applications and runs upstream's installer
# scripts, which stop a running client first and register the Finder extension
# for the logged-in user afterwards.
#
# Upstream builds its .pkg with the third-party Packages app from a project file
# full of build-machine paths (admin/osx/macosx.pkgproj); this does the same
# with Apple's own pkgbuild and productbuild.
#
# Usage: make-macos-pkg.sh <app> <staging-dir> <version> <out.pkg>
#   <staging-dir> is build-macos.sh's output: pre_install.sh, post_install.sh and
#   installer-background{,_2x}.png. With MACOS_INSTALLER_IDENTITY set (from
#   clients/macos-signing.sh import) the package is signed with it.

set -euo pipefail

BRANDING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
usage="usage: make-macos-pkg.sh <app> <staging-dir> <version> <out.pkg>"
APP="${1:?${usage}}"
STAGE="${2:?${usage}}"
VERSION="${3:?${usage}}"
OUT_PKG="${4:?${usage}}"

# shellcheck source=branding.env
. "${BRANDING_DIR}/branding.env"

die() { printf 'make-macos-pkg: %s\n' "$*" >&2; exit 1; }

[ -d "${APP}" ] || die "no app bundle at ${APP}"
[ "$(basename "${APP}")" = "${APPLICATION_NAME}.app" ] || die "expected ${APPLICATION_NAME}.app, got $(basename "${APP}")"
for f in pre_install.sh post_install.sh installer-background.png installer-background_2x.png; do
    [ -s "${STAGE}/${f}" ] || die "missing ${STAGE}/${f}"
done

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/root/Applications" "${work}/scripts" "${work}/resources" "${work}/packages"

# ditto keeps signatures, extended attributes and the framework symlinks intact.
ditto "${APP}" "${work}/root/Applications/${APPLICATION_NAME}.app"
cp "${STAGE}/pre_install.sh" "${work}/scripts/preinstall"
cp "${STAGE}/post_install.sh" "${work}/scripts/postinstall"
chmod 755 "${work}/scripts/preinstall" "${work}/scripts/postinstall"

# By default Installer "upgrades" a bundle with the same identifier wherever it
# finds one on disk (a copy on an external drive, a build folder). Turn that off
# for every bundle in the payload, so the app always lands in /Applications.
pkgbuild --analyze --root "${work}/root" "${work}/component.plist" >/dev/null
i=0
while /usr/libexec/PlistBuddy -c "Print :${i}" "${work}/component.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Set :${i}:BundleIsRelocatable false" "${work}/component.plist"
    i=$((i + 1))
done
[ "${i}" -gt 0 ] || die "pkgbuild found no bundle in the payload"

component="${APPLICATION_NAME}-app.pkg"
pkgbuild --root "${work}/root" --component-plist "${work}/component.plist" \
    --identifier "${APPLICATION_REV_DOMAIN}" --version "${VERSION}" \
    --scripts "${work}/scripts" --install-location / \
    "${work}/packages/${component}"

# One HiDPI image from the two renderings apply-branding.sh made.
tiffutil -cathidpicheck "${STAGE}/installer-background.png" "${STAGE}/installer-background_2x.png" \
    -out "${work}/resources/background.tiff"

min_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${APP}/Contents/Info.plist")"
title="$(printf '%s' "${APPLICATION_NAME}" | sed 's/&/\&amp;/g; s/</\&lt;/g')"
cat >"${work}/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>${title}</title>
    <background file="background.tiff" alignment="bottomleft" scaling="none"/>
    <background-darkAqua file="background.tiff" alignment="bottomleft" scaling="none"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_anywhere="false" enable_currentUserHome="false"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="${min_os}"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="${APPLICATION_REV_DOMAIN}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${APPLICATION_REV_DOMAIN}" visible="false">
        <pkg-ref id="${APPLICATION_REV_DOMAIN}"/>
    </choice>
    <pkg-ref id="${APPLICATION_REV_DOMAIN}" version="${VERSION}" onConclusion="none">${component}</pkg-ref>
</installer-gui-script>
EOF

mkdir -p "$(dirname "${OUT_PKG}")"
productbuild --distribution "${work}/distribution.xml" --resources "${work}/resources" \
    --package-path "${work}/packages" "${work}/unsigned.pkg"

# Signed separately with productsign: the import step grants productsign (not
# productbuild) access to the key, and productbuild --sign waits for a keychain
# prompt nobody can answer on a runner.
if [ -n "${MACOS_INSTALLER_IDENTITY:-}" ]; then
    keychain=()
    [ -z "${MACOS_KEYCHAIN:-}" ] || keychain=(--keychain "${MACOS_KEYCHAIN}")
    productsign --sign "${MACOS_INSTALLER_IDENTITY}" --timestamp "${keychain[@]+"${keychain[@]}"}" \
        "${work}/unsigned.pkg" "${OUT_PKG}"
else
    mv "${work}/unsigned.pkg" "${OUT_PKG}"
fi

if [ -n "${MACOS_INSTALLER_IDENTITY:-}" ]; then
    echo "built ${OUT_PKG}, signed by ${MACOS_INSTALLER_IDENTITY} (requires macOS ${min_os})"
else
    echo "built ${OUT_PKG}, unsigned (requires macOS ${min_os})"
fi
