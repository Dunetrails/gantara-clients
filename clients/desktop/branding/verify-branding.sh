#!/usr/bin/env bash
#
# Compliance sweep over a tree that apply-branding.sh has already rewritten.
# Fails when a user-visible Nextcloud mark survived, so the build stops instead
# of shipping one.
#
# Usage: verify-branding.sh <path-to-desktop-checkout>
#
# Three things are checked: that the branding landed, that the artwork was
# replaced, and that nothing carrying the mark is left where a user could see
# it. The last one is deliberately blunt — every case-insensitive "nextcloud"
# in the Linux source, the theme and the packaging counts as a failure unless
# it matches KEEP below. Adding to KEEP is a decision to ship that occurrence,
# so every entry says why it is safe.

set -euo pipefail

BRANDING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="${1:?usage: verify-branding.sh <path-to-desktop-checkout>}"
DESKTOP="$(cd -- "${DESKTOP}" && pwd)"

# shellcheck source=branding.env
. "${BRANDING_DIR}/branding.env"

failures=0
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf 'ok    %s\n' "$*"; }

cd "${DESKTOP}"

expect_in_file() {
    local file="$1" needle="$2" what="$3"
    if [ -f "${file}" ] && grep -qF -- "${needle}" "${file}"; then
        pass "${what}"
    else
        fail "${what} — expected \"${needle}\" in ${file}"
    fi
}

# --------------------------------------------------------------------------
# The branding landed
# --------------------------------------------------------------------------
expect_in_file NEXTCLOUD.cmake "set( APPLICATION_NAME       \"${APPLICATION_NAME}\" )" \
    "product name overridden"
expect_in_file NEXTCLOUD.cmake "set( APPLICATION_EXECUTABLE \"${APPLICATION_EXECUTABLE}\" )" \
    "executable name overridden"
expect_in_file NEXTCLOUD.cmake "set( APPLICATION_REV_DOMAIN \"${APPLICATION_REV_DOMAIN}\" )" \
    "reverse-DNS identity overridden"
expect_in_file NEXTCLOUD.cmake "set( APPLICATION_CONFIG_NAME \"${APPLICATION_EXECUTABLE}\" )" \
    "settings filename overridden"
expect_in_file NEXTCLOUD.cmake "set( LINUX_APPLICATION_ID    \"${APPLICATION_REV_DOMAIN}.${LINUX_PACKAGE_SHORTNAME}\" )" \
    "desktop-entry / D-Bus id overridden"
expect_in_file NEXTCLOUD.cmake "set( BUILD_UPDATER OFF )" \
    "updater disabled"
expect_in_file NEXTCLOUD.cmake "set( WIN_SHELLEXT_CONTEXT_MENU_GUID      \"${WIN_SHELLEXT_CONTEXT_MENU_GUID}\" )" \
    "Windows Explorer context-menu GUID overridden"
expect_in_file NEXTCLOUD.cmake "set( WIN_MSI_UPGRADE_CODE                \"${WIN_MSI_UPGRADE_CODE}\" )" \
    "Windows MSI UpgradeCode overridden"
expect_in_file CMakeLists.txt "set( CFAPI_SHELLEXT_APPID_REG \"${CFAPI_SHELLEXT_APPID_REG}\")" \
    "Windows CfApi AppId GUID overridden"

# Identities that upstream derives from the display name, pinned to the short
# name so renaming the product does not orphan existing installs.
expect_in_file src/libsync/configfile.cpp 'qApp->setApplicationName(Theme::instance()->appName());' \
    "settings directory keyed on APPLICATION_SHORTNAME"
expect_in_file src/gui/folder.cpp 'vfsParams.providerName = Theme::instance()->appName();' \
    "CfApi sync-root provider keyed on APPLICATION_SHORTNAME"
expect_in_file src/gui/navigationpanehelper.cpp 'const auto currentAppName = QLatin1String(APPLICATION_SHORTNAME);' \
    "Explorer sidebar entry keyed on APPLICATION_SHORTNAME"
expect_in_file src/libsync/settings/devicesources.cpp 'ConfigFile::unbrandedAppName) : Theme::instance()->appName();' \
    "policy registry path keyed on APPLICATION_SHORTNAME"

# Our block is appended, so the effective value of anything set twice is the
# last one. Checking that literally is what proves the override wins.
effective_update_url="$(grep -E '^[[:space:]]*set\([[:space:]]*APPLICATION_UPDATE_URL' NEXTCLOUD.cmake | tail -n1)"
case "${effective_update_url}" in
    *"${APPLICATION_UPDATE_URL}"*) pass "effective update URL is ours, not the Nextcloud appcast" ;;
    *) fail "last APPLICATION_UPDATE_URL in NEXTCLOUD.cmake is not ours: ${effective_update_url}" ;;
esac

# Upstream's own branding switch. It is what makes the build compile the plain
# status glyphs into the tray instead of the Nextcloud-logo ones, so if a future
# tag drops it the tray silently goes back to the Nextcloud mark.
expect_in_file src/gui/CMakeLists.txt 'if(APPLICATION_NAME STREQUAL "Nextcloud"' \
    "upstream's neutral-tray-icon switch still present"

# --------------------------------------------------------------------------
# The artwork was replaced
# --------------------------------------------------------------------------
# apply-branding.sh stamps data-brand="gantara" on every SVG it writes, which is
# what proves the upstream vector logo is gone rather than merely renamed.
for svg in "theme/colored/${APPLICATION_ICON_NAME}-icon.svg" \
           theme/colored/wizard_logo.svg \
           "theme/colored/${APPLICATION_ICON_NAME}-w10startmenu.svg" \
           "theme/colored/icons/${APPLICATION_ICON_NAME}-icon-win-folder.svg"; do
    if [ -s "${svg}" ] && grep -qF 'data-brand="gantara"' "${svg}"; then
        pass "brand artwork in ${svg}"
    else
        fail "brand artwork missing from ${svg}"
    fi
done

if [ -s "theme/${APPLICATION_EXECUTABLE}.VisualElementsManifest.xml" ] \
        && grep -qF "${APPLICATION_ICON_NAME}-w10startmenu.png" \
            "theme/${APPLICATION_EXECUTABLE}.VisualElementsManifest.xml"; then
    pass "Windows Start-tile manifest is branded"
else
    fail "Windows Start-tile manifest missing or still Nextcloud-named"
fi
if [ -f theme/nextcloud.VisualElementsManifest.xml ]; then
    fail "upstream nextcloud.VisualElementsManifest.xml still present"
else
    pass "upstream nextcloud.VisualElementsManifest.xml removed"
fi

missing_slides=0
for flavor in colored black white; do
    for png in "theme/${flavor}/wizard-nextcloud.png" "theme/${flavor}/wizard-nextcloud@2x.png"; do
        [ -s "${png}" ] || { fail "wizard slide not written: ${png}"; missing_slides=1; }
    done
done
[ "${missing_slides}" -eq 0 ] && pass "wizard slide bitmaps written for every flavour"

leftover_logos="$(find theme -name 'Nextcloud-*' -print -o -type d -name 'nextcloud' -print 2>/dev/null)"
if [ -z "${leftover_logos}" ]; then
    pass "no Nextcloud logo artwork left in theme/"
else
    fail "Nextcloud logo artwork still present:"$'\n'"${leftover_logos}"
fi

# --------------------------------------------------------------------------
# Nothing user-visible carries the mark
# --------------------------------------------------------------------------
KEEP=(
    # Server protocol. WebDAV property namespaces, the subdirectory probe that
    # finds a server installed under /nextcloud/, the organisation field of the
    # end-to-end-encryption certificate request, and the extended attributes
    # stamped on placeholder files. All of these travel to or from the server or
    # the filesystem; renaming them breaks sync.
    'nextcloud\.org/ns:'
    '\{"O","Nextcloud"\}'
    'nextcloudDirC'
    'user\.nextcloud\.'

    # Identifiers, never rendered. The QML module URI every .qml file imports,
    # C++ class names, the translation context of the About dialog, exported
    # symbol macros, and Qt logging categories plus the lines that log through
    # them.
    'com[._]nextcloud[._]desktopclient'
    'Nextcloud(Theme|SslCertificate)|SoftwareNextcloudCertificate|nextcloudTheme::'

    # Developer switches read from the environment; renaming them would only
    # break upstream's own debugging instructions.
    'qgetenv\("NEXTCLOUD_|EnvVar = "NEXTCLOUD_'
    '(has|add)NextcloudPlaceholderAttributes'
    'NEXTCLOUD_(CFAPI|XATTR)_EXPORT'
    'Q_LOGGING_CATEGORY|qC[A-Z][A-Za-z]*\('

    # Preprocessor symbols out of config.h: the minimum server versions the
    # client feature-gates on, the upstream dev-build flag, and the default
    # account colour, which apply-branding.sh sets to ours.
    'NEXTCLOUD_SERVER_VERSION|NEXTCLOUD_DEV|NEXTCLOUD_BACKGROUND_COLOR'

    # Reading an existing Nextcloud install's settings so its account can be
    # imported, and the check for "am I still called Nextcloud?" that drives
    # Theme::isBranded(). Both are only correct unbranded. On Windows the
    # Explorer-favorites migrator matches a leftover "Nextcloud" / "Nextcloud2"
    # folder name the same way — the comparison string stays the official
    # product name; the local is named after it.
    'unbranded(AppName|ApplicationName|CfgFileNameC|RelativeConfigLocationC)'
    'Q(String|ByteArray)Literal\("Nextcloud"\)'
    'const auto nextcloud ='
    'startsWith\(nextcloud\)'

    # Diagnostics. The log filename and the debug-archive scratch file, plus the
    # two probe files the folder watcher writes — those two are named in
    # sync-exclude.lst, so renaming them would start syncing them.
    'nextcloud\.log|nextcloud-debug-archive|nextcloud\.\*\.debug'
    'nextcloudsync\.log|nextcloudpermissions\.log'

    # Attribution the GPL requires us to keep (About dialog, Legal notice), and
    # the SPDX headers of .ui files, which sit inside a multi-line comment.
    'Copyright 20[0-9][0-9]-20[0-9][0-9] Nextcloud GmbH'
    'SPDX-FileCopyrightText: .*Nextcloud GmbH'

    # A translator hint passed as tr()'s disambiguation argument. Never shown,
    # and it is part of the key a translation is looked up by.
    '"Open Nextcloud main window'

    # Filenames whose artwork apply-branding.sh replaced. theme.qrc.in compiles
    # the wizard slide in under upstream's name; the bitmap behind it is ours.
    'wizard-?[Nn]extcloud'

    # macOS file-provider headers referenced from shared sources; we do not
    # build or ship those modules.
    'Nextcloud(Integration|FileProviderKit|FileProviderXPC)'

    # Unused WiX/MSI source filename mentioned in a Windows comment. Craft
    # packages NSIS; BUILD_WIN_MSI stays off.
    'Nextcloud\.wxs'

    # An upstream doc comment that the comment filter below cannot see, because
    # it is a continuation line inside a /* */ block.
    'client_updater_server'
)
keep_re="$(IFS='|'; printf '%s' "${KEEP[*]}")"

# Scope: what a Linux or Windows build actually compiles and installs. Excluded
# are macOS sources, the updater (BUILD_UPDATER is OFF), upstream's Debian/PPA
# publishing scripts, and the cmake target and library names, which are
# build-system identifiers rather than anything shipped. NEXTCLOUD.cmake is
# excluded too: its upstream defaults are still in the file by design, superseded
# by the appended block that the checks above verify. /cfapi/ is COM class
# wiring whose display names already come from APPLICATION_NAME. WinShellExt.wxs.in
# is the unused WiX/MSI source; Craft packages NSIS and BUILD_WIN_MSI stays off.
hits="$(
    grep -rn -i -E 'nextcloud' \
        --include='*.cpp' --include='*.h' --include='*.ui' --include='*.qml' \
        --include='*.xml' --include='*.in' --include='*.sh' \
        src theme admin/linux/build-appimage.sh theme.qrc.in mirall.desktop.in \
        shell_integration/windows 2>/dev/null \
    | grep -v -E '(_mac[a-z_]*)\.(cpp|h)|/[Mm]acOS|/cfapi/|^src/gui/updater/' \
    | grep -v -F 'WinShellExt.wxs.in' \
    | grep -v -E ':[0-9]+:[[:space:]]*(//|\*|/\*|#|<!--)' \
    | sed -e 's: //.*::' \
    | grep -i -E 'nextcloud' \
    | grep -v -E "${keep_re}" \
    || true
)"
if [ -z "${hits}" ]; then
    pass "no user-visible Nextcloud mark in the Linux/Windows source, theme or packaging"
else
    fail "user-visible Nextcloud marks left behind:"$'\n'"${hits}"
fi

# The translation catalogues lag the source: they still carry <source> entries
# for strings upstream has since changed, several of which name Nextcloud. Those
# are unreachable, because Qt looks a translation up by the source text the
# binary asks for. Rather than trust that, check it — if any <source> carrying
# the mark is a literal the rebranded source still asks for, it is live and the
# build must fail.
ts_sources="$(mktemp)"
trap 'rm -f "${ts_sources}"' EXIT
grep -rhoE '<source>[^<]*[Nn]extcloud[^<]*</source>' translations 2>/dev/null \
    | sed -e 's:</\?source>::g' \
          -e 's:&quot;:":g' -e "s:&apos;:':g" \
          -e 's:&lt;:<:g' -e 's:&gt;:>:g' -e 's:&amp;:\&:g' \
    | sort -u >"${ts_sources}"

if [ ! -s "${ts_sources}" ]; then
    pass "no Nextcloud mark in the translation catalogues"
elif live="$(grep -rnF -f "${ts_sources}" \
        --include='*.cpp' --include='*.h' --include='*.ui' --include='*.qml' src 2>/dev/null)" \
        && [ -n "${live}" ]; then
    fail "translated strings naming Nextcloud are still asked for by the source:"$'\n'"${live}"
else
    pass "$(wc -l <"${ts_sources}" | tr -d ' ') stale translation entries name Nextcloud; none is reachable from the source"
fi

printf '\n'
if [ "${failures}" -ne 0 ]; then
    printf 'verify-branding: %s check(s) failed\n' "${failures}" >&2
    exit 1
fi
printf 'verify-branding: clean\n'
