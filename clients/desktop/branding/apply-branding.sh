#!/usr/bin/env bash
#
# Rebrand a checked-out nextcloud/desktop tree as Gantara, in place.
#
# Usage: apply-branding.sh <path-to-desktop-checkout>
#
# We do not maintain a fork. The pipeline checks out a pinned upstream tag and
# runs this script on it, so following a new upstream release is a tag bump.
#
# Scope: names, identifiers, links and artwork. Nothing here changes what the
# client does. Every edit anchors on an exact upstream literal and the script
# aborts when an anchor is missing, so a moved string fails the build instead of
# silently shipping a Nextcloud mark. Written against v35.0.x.
#
# The product is shown as APPLICATION_NAME (Gantara) but was first shipped as
# Dunetrails. Upstream derives a few identities from the display name — the
# settings directory, the CfApi sync-root id, the Explorer sidebar entry — so
# those lookups are pinned to APPLICATION_SHORTNAME, which keeps the original
# name. Existing installs keep their accounts and sync folders.
#
# Linux and Windows share this overlay. Windows-only work is the shell-extension
# GUIDs, the Start-tile manifest, and the NSIS installer icon; the rest of the
# rewrites land in both builds.

set -euo pipefail

BRANDING_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DESKTOP="${1:?usage: apply-branding.sh <path-to-desktop-checkout>}"
DESKTOP="$(cd -- "${DESKTOP}" && pwd)"

# shellcheck source=branding.env
. "${BRANDING_DIR}/branding.env"

LOGO_ICO="${BRANDING_DIR}/assets/logo.ico"
STAR_COLOR="${BRANDING_DIR}/assets/gantara-symbol-color.svg"
HORIZONTAL_COLOR="${BRANDING_DIR}/assets/gantara-horizontal-color.svg"
HORIZONTAL_ON_DARK="${BRANDING_DIR}/assets/gantara-horizontal-color-on-dark.svg"

die() { printf 'apply-branding: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

need_file() {
    [ -f "$1" ] || die "expected file is missing: ${1#"${DESKTOP}"/} (upstream moved it?)"
}

# sed metacharacter escaping, so every rewrite below is a literal replacement.
esc_lhs() { printf '%s' "$1" | sed 's:[][\\.^$*/]:\\&:g'; }
esc_rhs() { printf '%s' "$1" | sed 's:[\\&/]:\\&:g'; }

# Replace an exact literal, failing if it is not there.
rewrite() {
    local file="$1" from="$2" to="$3"
    need_file "${file}"
    grep -qF -- "${from}" "${file}" \
        || die "anchor not found in ${file#"${DESKTOP}"/}: ${from}"
    sed -i "s/$(esc_lhs "${from}")/$(esc_rhs "${to}")/g" "${file}"
    printf '    %s: %s\n' "${file#"${DESKTOP}"/}" "${from}"
}

# Same, but a no-op when the literal is absent. Only for the translation
# catalogues, where a given message exists in some languages and not others.
rewrite_optional() {
    local file="$1" from="$2" to="$3"
    grep -qF -- "${from}" "${file}" 2>/dev/null || return 0
    sed -i "s/$(esc_lhs "${from}")/$(esc_rhs "${to}")/g" "${file}"
}

need_file "${DESKTOP}/NEXTCLOUD.cmake"
for asset in "${LOGO_ICO}" "${STAR_COLOR}" "${HORIZONTAL_COLOR}" "${HORIZONTAL_ON_DARK}"; do
    [ -f "${asset}" ] || die "missing brand asset: ${asset}"
done
[ "${APPLICATION_SHORTNAME}" = "Dunetrails" ] \
    || die "APPLICATION_SHORTNAME must stay Dunetrails: it names existing installs' settings and sync roots"

# The rewrites consume their anchors, so a second pass would fail confusingly
# partway through. Say so up front instead.
BRANDING_MARKER="---- ${APPLICATION_NAME} branding"
if grep -qF -- "${BRANDING_MARKER}" "${DESKTOP}/NEXTCLOUD.cmake"; then
    die "this tree is already branded — run against a fresh checkout"
fi

# --------------------------------------------------------------------------
step "Branding variables (NEXTCLOUD.cmake override block)"
# --------------------------------------------------------------------------
# CMakeLists.txt include()s NEXTCLOUD.cmake top-to-bottom before it configures
# config.h, so appending wins over the upstream defaults. The two derived
# variables have to be recomputed here: upstream expands them at the point of
# definition, from values we are about to replace.

cat >>"${DESKTOP}/NEXTCLOUD.cmake" <<EOF

# ${BRANDING_MARKER} (appended by clients/desktop/branding/apply-branding.sh) ----
set( APPLICATION_NAME       "${APPLICATION_NAME}" )
set( APPLICATION_SHORTNAME  "${APPLICATION_SHORTNAME}" )
set( APPLICATION_EXECUTABLE "${APPLICATION_EXECUTABLE}" )
set( APPLICATION_ICON_NAME  "${APPLICATION_ICON_NAME}" )
set( APPLICATION_DOMAIN     "${APPLICATION_DOMAIN}" )
set( APPLICATION_VENDOR     "${APPLICATION_VENDOR}" )
set( APPLICATION_REV_DOMAIN "${APPLICATION_REV_DOMAIN}" )

# Derived upstream from APPLICATION_EXECUTABLE / APPLICATION_REV_DOMAIN before
# the values above existed, so they need setting again. APPLICATION_CONFIG_NAME
# is the settings filename; LINUX_APPLICATION_ID the .desktop / D-Bus id.
set( APPLICATION_CONFIG_NAME "${APPLICATION_EXECUTABLE}" )
set( LINUX_PACKAGE_SHORTNAME "${LINUX_PACKAGE_SHORTNAME}" )
set( LINUX_APPLICATION_ID    "${APPLICATION_REV_DOMAIN}.${LINUX_PACKAGE_SHORTNAME}" )

set( APPLICATION_VIRTUALFILE_SUFFIX "${APPLICATION_VIRTUALFILE_SUFFIX}" )

set( APPLICATION_HELP_URL   "${APPLICATION_HELP_URL}" )
set( APPLICATION_UPDATE_URL "${APPLICATION_UPDATE_URL}" )

set( NEXTCLOUD_BACKGROUND_COLOR                 "${BRAND_BACKGROUND_COLOR}" )
set( APPLICATION_WIZARD_HEADER_BACKGROUND_COLOR "${BRAND_BACKGROUND_COLOR}" )
set( APPLICATION_WIZARD_HEADER_TITLE_COLOR      "${BRAND_FONT_COLOR}" )

# Windows: unique Explorer overlay / context-menu / MSI UpgradeCode GUIDs so
# we never collide with an official Nextcloud install on the same machine.
set( WIN_SHELLEXT_CONTEXT_MENU_GUID      "${WIN_SHELLEXT_CONTEXT_MENU_GUID}" )
set( WIN_SHELLEXT_OVERLAY_GUID_ERROR     "${WIN_SHELLEXT_OVERLAY_GUID_ERROR}" )
set( WIN_SHELLEXT_OVERLAY_GUID_OK        "${WIN_SHELLEXT_OVERLAY_GUID_OK}" )
set( WIN_SHELLEXT_OVERLAY_GUID_OK_SHARED "${WIN_SHELLEXT_OVERLAY_GUID_OK_SHARED}" )
set( WIN_SHELLEXT_OVERLAY_GUID_SYNC      "${WIN_SHELLEXT_OVERLAY_GUID_SYNC}" )
set( WIN_SHELLEXT_OVERLAY_GUID_WARNING   "${WIN_SHELLEXT_OVERLAY_GUID_WARNING}" )
set( WIN_MSI_UPGRADE_CODE                "${WIN_MSI_UPGRADE_CODE}" )

# No self-hosted appcast, so no updater. The AppImage / Craft builds pass this
# too; pinning it here means a plain cmake run of the branded tree cannot
# quietly build an updater that would poll APPLICATION_UPDATE_URL.
set( BUILD_UPDATER OFF )

# THEME_CLASS is deliberately left as NextcloudTheme: it is a C++ class name
# referenced across the source, not a string anyone sees.
EOF

# --------------------------------------------------------------------------
step "Windows CfApi shell-extension GUIDs"
# --------------------------------------------------------------------------
# These are set in CMakeLists.txt AFTER NEXTCLOUD.cmake is include()d, so the
# append above cannot win. Rewrite the hardcoded Nextcloud values in place.
rewrite "${DESKTOP}/CMakeLists.txt" \
    'set( CFAPI_SHELLEXT_APPID_REG "{E314A650-DCA4-416E-974E-18EA37C213EA}")' \
    "set( CFAPI_SHELLEXT_APPID_REG \"${CFAPI_SHELLEXT_APPID_REG}\")"
rewrite "${DESKTOP}/CMakeLists.txt" \
    'set( CFAPI_SHELLEXT_CUSTOM_STATE_HANDLER_CLASS_ID "1E62D59A-6EA4-476C-B707-4A32E88ED822" )' \
    "set( CFAPI_SHELLEXT_CUSTOM_STATE_HANDLER_CLASS_ID \"${CFAPI_SHELLEXT_CUSTOM_STATE_HANDLER_CLASS_ID}\" )"
rewrite "${DESKTOP}/CMakeLists.txt" \
    'set( CFAPI_SHELLEXT_THUMBNAIL_HANDLER_CLASS_ID "6FF9B5B6-389F-444A-9FDD-A286C36EA079" )' \
    "set( CFAPI_SHELLEXT_THUMBNAIL_HANDLER_CLASS_ID \"${CFAPI_SHELLEXT_THUMBNAIL_HANDLER_CLASS_ID}\" )"

# --------------------------------------------------------------------------
step "Identity lookups pinned to APPLICATION_SHORTNAME"
# --------------------------------------------------------------------------
# Theme::appName() is APPLICATION_SHORTNAME; appNameGUI() is APPLICATION_NAME.
# Keychain entries and the autostart file already use appName(). These do not:

# QStandardPaths names the settings directory (~/.config/<name>,
# %APPDATA%\<name>) after the application name set here.
rewrite "${DESKTOP}/src/libsync/configfile.cpp" \
    'qApp->setApplicationName(Theme::instance()->appNameGUI());' \
    'qApp->setApplicationName(Theme::instance()->appName());'
# Admin-deployed defaults and policies (/etc/<name>/<name>.conf, HKLM/HKCU keys).
rewrite "${DESKTOP}/src/libsync/configfile.cpp" \
    'const auto appName = Migration::isUnbrandedToBrandedMigration() ? unbrandedAppName : Theme::instance()->appNameGUI();' \
    'const auto appName = Migration::isUnbrandedToBrandedMigration() ? unbrandedAppName : Theme::instance()->appName();'
rewrite "${DESKTOP}/src/libsync/settings/devicesources.cpp" \
    'QString::fromLatin1(ConfigFile::unbrandedAppName) : Theme::instance()->appNameGUI();' \
    'QString::fromLatin1(ConfigFile::unbrandedAppName) : Theme::instance()->appName();'
# Windows virtual files: the provider name is the first part of every sync-root id.
rewrite "${DESKTOP}/src/gui/folder.cpp" \
    'vfsParams.providerName = Theme::instance()->appNameGUI();' \
    'vfsParams.providerName = Theme::instance()->appName();'
# Windows Explorer sidebar: entries are found again (and cleaned up) by this value.
rewrite "${DESKTOP}/src/gui/navigationpanehelper.cpp" \
    'const auto currentAppName = QLatin1String(APPLICATION_NAME);' \
    'const auto currentAppName = QLatin1String(APPLICATION_SHORTNAME);'
rewrite "${DESKTOP}/src/gui/navigationpanehelper.cpp" \
    'QStringLiteral("ApplicationName"), REG_SZ, QLatin1String(APPLICATION_NAME));' \
    'QStringLiteral("ApplicationName"), REG_SZ, QLatin1String(APPLICATION_SHORTNAME));'

# --------------------------------------------------------------------------
step "Artwork"
# --------------------------------------------------------------------------
# The client rasterises its icons from SVG at build time (APPLICATION_ICON_SET
# is "SVG"), so the brand vectors are placed into SVGs of the size each slot
# expects. cmake requires inkscape or rsvg-convert to configure at all, which is
# also what we use for the bitmaps Qt loads by a fixed .png name.
#
# On Windows the Chocolatey Inkscape install is on the machine PATH, but a
# Git Bash step in the same job may not have picked it up yet.

if ! command -v inkscape >/dev/null 2>&1 && ! command -v rsvg-convert >/dev/null 2>&1; then
    for d in "/c/Program Files/Inkscape/bin" "/c/Program Files/Inkscape" \
             "/c/Program Files (x86)/Inkscape/bin"; do
        if [ -x "${d}/inkscape.exe" ]; then
            PATH="${d}:${PATH}"
            export PATH
            break
        fi
    done
fi

SVG_CONVERTER=""
for candidate in inkscape inkscape.exe rsvg-convert; do
    if command -v "${candidate}" >/dev/null 2>&1; then
        SVG_CONVERTER="${candidate}"
        break
    fi
done
[ -n "${SVG_CONVERTER}" ] || die "need inkscape or rsvg-convert on PATH (the cmake build requires one too)"

THEME="${DESKTOP}/theme"

# The brand files are one root <svg> line, a <title> and plain paths, so their
# body can be nested as-is (no ids or styles to collide).
svg_viewbox() { tr -d '\r' < "$1" | grep -o 'viewBox="[^"]*"' | head -n1 | sed -e 's/^viewBox="//' -e 's/"$//'; }
svg_body() { tr -d '\r' < "$1" | sed -e '1d' -e '/<\/svg>/d' -e '/<title>/d'; }

# <svg> element placing brand file $1 in the box x=$2 y=$3 w=$4 h=$5, centred.
nested_logo() {
    printf '<svg x="%s" y="%s" width="%s" height="%s" viewBox="%s" preserveAspectRatio="xMidYMid meet">\n%s\n</svg>' \
        "$2" "$3" "$4" "$5" "$(svg_viewbox "$1")" "$(svg_body "$1")"
}

# Square: the colour star on transparency, the brand's application icon. The
# Talk client uses a white star on a blue tile, so the two stay apart in a tray.
write_square_svg() {
    cat >"$1" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" data-brand="gantara" width="512" height="512" viewBox="0 0 512 512">
$(nested_logo "${STAR_COLOR}" 16 16 480 480)
</svg>
EOF
}

# 2:1, horizontal logo centred: matches the aspect of the bitmaps it replaces.
# The welcome page paints those slides at their native size, so the aspect has
# to hold or the wizard changes shape. $2 picks the variant for the background.
write_wide_svg() {
    cat >"$1" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" data-brand="gantara" width="200" height="100" viewBox="0 0 200 100">
$(nested_logo "$2" 10 10 180 80)
</svg>
EOF
}

WIDE_ON_LIGHT="$(mktemp --suffix=.svg)"
WIDE_ON_DARK="$(mktemp --suffix=.svg)"
trap 'rm -f "${WIDE_ON_LIGHT}" "${WIDE_ON_DARK}"' EXIT
write_wide_svg "${WIDE_ON_LIGHT}" "${HORIZONTAL_COLOR}"
write_wide_svg "${WIDE_ON_DARK}" "${HORIZONTAL_ON_DARK}"

rasterise() {
    local svg="$1" width="$2" height="$3" out="$4"
    local out_arg="${out}"
    # Native Windows Inkscape does not understand Git Bash /tmp paths.
    if command -v cygpath >/dev/null 2>&1; then
        svg="$(cygpath -w "${svg}")"
        out_arg="$(cygpath -w "${out}")"
    fi
    "${SVG_CONVERTER}" -w "${width}" -h "${height}" "${svg}" -o "${out_arg}" \
        || die "${SVG_CONVERTER} failed to write ${out#"${DESKTOP}"/}"
    [ -s "${out}" ] || die "${SVG_CONVERTER} produced an empty ${out#"${DESKTOP}"/}"
}

# The application icon. theme.qrc.in and src/gui/CMakeLists.txt both reach for
# theme/colored/<APPLICATION_ICON_NAME>-icon.svg, so this filename is required.
need_file "${THEME}/colored/Nextcloud-icon.svg"
write_square_svg "${THEME}/colored/${APPLICATION_ICON_NAME}-icon.svg"
printf '    theme/colored/%s-icon.svg (application icon)\n' "${APPLICATION_ICON_NAME}"

# The wizard logo (Theme::wizardApplicationLogo / wizardHeaderLogo) and the old
# wizard's first slide. The QML account wizard in v35 shows neither, but
# theme.qrc.in still compiles all of them into the binary, so replace the
# artwork rather than trusting a code path to stay dead.
need_file "${THEME}/colored/wizard_logo.svg"
cp -f "${WIDE_ON_LIGHT}" "${THEME}/colored/wizard_logo.svg"
rasterise "${WIDE_ON_LIGHT}" 200 100 "${THEME}/colored/wizard_logo.png"
rasterise "${WIDE_ON_LIGHT}" 400 200 "${THEME}/colored/wizard_logo@2x.png"
printf '    theme/colored/wizard_logo.{svg,png,@2x.png} (wizard logo)\n'

# Slides come in flavours for the window background: white artwork is the one
# for dark windows.
for flavor in colored black white; do
    need_file "${THEME}/${flavor}/wizard-nextcloud.png"
    wide="${WIDE_ON_LIGHT}"
    [ "${flavor}" = white ] && wide="${WIDE_ON_DARK}"
    rasterise "${wide}" 200 100 "${THEME}/${flavor}/wizard-nextcloud.png"
    rasterise "${wide}" 400 200 "${THEME}/${flavor}/wizard-nextcloud@2x.png"
    rm -f "${THEME}/${flavor}/wizard-nextcloud.svg"
    printf '    theme/%s/wizard-nextcloud.{png,@2x.png} (wizard slide)\n' "${flavor}"
done

# Drop the Nextcloud logo artwork the branded build no longer references:
# the app icon in its various platform shapes, and the Nextcloud-logo tray
# icons. Those tray icons are already unreachable — src/gui/CMakeLists.txt
# points theme.qrc at theme/<flavor>/state-*.svg (plain status glyphs, no logo)
# as soon as APPLICATION_NAME stops being "Nextcloud" — so this only keeps them
# out of the tree and out of the icon rasterisation.
rm -f "${THEME}"/colored/Nextcloud-*.svg \
      "${THEME}"/colored/Nextcloud-*.png \
      "${THEME}"/colored/icons/Nextcloud-*.svg
rm -rf "${THEME}"/colored/nextcloud "${THEME}"/black/nextcloud "${THEME}"/white/nextcloud
# macOS Icon Composer bundle. NEXTCLOUD.cmake only uses it when its icon.json
# exists, and only on Apple; the other platforms take the SVG app icon above.
rm -rf "${THEME}"/colored/AppIcon.icon
printf '    removed unreferenced Nextcloud logo artwork\n'

# Windows Start tile. cmake looks for theme/colored/<APPLICATION_ICON_NAME>-
# w10startmenu.svg, rasterises 70/150 PNGs, and installs
# theme/<APPLICATION_EXECUTABLE>.VisualElementsManifest.xml into bin/. Without
# these the Windows Craft install fails looking for dunetrails.VisualElements…
write_square_svg "${THEME}/colored/${APPLICATION_ICON_NAME}-w10startmenu.svg"
mkdir -p "${THEME}/colored/icons"
write_square_svg "${THEME}/colored/icons/${APPLICATION_ICON_NAME}-icon-win-folder.svg"
cat >"${DESKTOP}/theme/${APPLICATION_EXECUTABLE}.VisualElementsManifest.xml" <<XML
<Application xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>
  <VisualElements
	ForegroundText="light"
  ShowNameOnSquare150x150Logo="on"
  Square150x150Logo="visualelements\\150-${APPLICATION_ICON_NAME}-w10startmenu.png"
	Square70x70Logo="visualelements\\70-${APPLICATION_ICON_NAME}-w10startmenu.png"/>
</Application>
XML
rm -f "${DESKTOP}/theme/nextcloud.VisualElementsManifest.xml"
printf '    theme/colored/%s-w10startmenu.svg + %s.VisualElementsManifest.xml\n' \
    "${APPLICATION_ICON_NAME}" "${APPLICATION_EXECUTABLE}"

# NSIS installer.ico (WIN_SETUP_BITMAP_PATH). Craft's Nullsoft packager uses
# the .ico staged by build-windows.ps1; this covers the cmake NSIS path too.
need_file "${DESKTOP}/admin/win/nsi/installer.ico"
cp -f "${LOGO_ICO}" "${DESKTOP}/admin/win/nsi/installer.ico"
printf '    admin/win/nsi/installer.ico (NSIS / setup icon)\n'

# --------------------------------------------------------------------------
step "AppImage build script"
# --------------------------------------------------------------------------
# We build with upstream's own admin/linux/build-appimage.sh. The icon is
# installed as <APPLICATION_ICON_NAME>.png, but the script hands linuxdeploy the
# name hardcoded, and its two brand defaults would otherwise decide the
# AppImage's name and its bundled data directory whenever the environment does
# not override them.
rewrite "${DESKTOP}/admin/linux/build-appimage.sh" \
    "usr/share/icons/hicolor/512x512/apps/Nextcloud.png" \
    "usr/share/icons/hicolor/512x512/apps/${APPLICATION_ICON_NAME}.png"
rewrite "${DESKTOP}/admin/linux/build-appimage.sh" \
    'export APPNAME=${APPNAME:-Nextcloud}' \
    "export APPNAME=\${APPNAME:-${APPLICATION_NAME}}"
rewrite "${DESKTOP}/admin/linux/build-appimage.sh" \
    'export EXECUTABLE_NAME=${EXECUTABLE_NAME:-nextcloud}' \
    "export EXECUTABLE_NAME=\${EXECUTABLE_NAME:-${APPLICATION_EXECUTABLE}}"

# --------------------------------------------------------------------------
step "Links and names in the source"
# --------------------------------------------------------------------------
# What the cmake variables cannot reach: literals typed out in the code.

# Add-account wizard: the hint in the server-address field, which the QML
# wizard reads from the theme.
rewrite "${DESKTOP}/src/libsync/nextcloudtheme.cpp" \
    "https://try.nextcloud.com" "${APPLICATION_WIZARD_URL_HINT}"

# Add-account wizard: "Sign up with a provider" and "Host your own server".
rewrite "${DESKTOP}/src/gui/wizard/accountwizardcontroller.cpp" \
    "https://nextcloud.com/sign-up/?flow=V3" "${BRAND_SIGNUP_URL}"
rewrite "${DESKTOP}/src/gui/wizard/accountwizardcontroller.cpp" \
    "https://docs.nextcloud.com/server/latest/admin_manual/installation/#installation" \
    "${BRAND_SITE_URL}"

# Settings: the "Client Push" link next to the poll interval.
rewrite "${DESKTOP}/src/gui/advancedsettings.ui" \
    "https://github.com/nextcloud/notify_push" "${BRAND_SITE_URL}"

# Help menu fallback. Unreachable now that APPLICATION_HELP_URL is set (which is
# what the Help menu and the conflict help both use), rewritten anyway.
rewrite "${DESKTOP}/src/libsync/theme.cpp" \
    "https://docs.nextcloud.com/server/latest/user_manual/en/desktop/index.html" \
    "${APPLICATION_HELP_URL}"

# About dialog: the build revision is a link to upstream's commit browser. We
# have no public one, so point it at the site. Dropping the link instead would
# mean dropping a QString::arg() placeholder, which shifts the build date and
# library versions into the wrong slots.
rewrite "${DESKTOP}/src/libsync/theme.cpp" \
    "https://github.com/nextcloud/desktop/commit/" "${BRAND_SITE_URL}/"

# About dialog: "This release was supplied by %1." APPLICATION_VENDOR keeps the
# original name because it is part of D-Bus and registry policy paths.
rewrite "${DESKTOP}/src/libsync/theme.cpp" \
    ".arg(APPLICATION_VENDOR);" ".arg(APPLICATION_NAME);"

# Command-line help of the GUI client and of the CLI sync tool (not translated).
rewrite "${DESKTOP}/src/gui/application.cpp" \
    "Enable debug messages in Nextcloud logging categories." \
    "Enable debug messages in the client's logging categories."
rewrite "${DESKTOP}/src/cmd/cmd.cpp" \
    "see nextcloud/desktop#2916, #7682)" "see upstream issues #2916, #7682)"
rewrite "${DESKTOP}/src/cmd/cmd.cpp" \
    "The base URL of the Nextcloud server" "The base URL of the server"

# The Assistant's system prompt names the product to the model, and its empty
# chat invites the user to talk to it.
rewrite "${DESKTOP}/src/gui/assistant/ocsassistantconnector.cpp" \
    "you, Nextcloud Assistant." "you, ${APPLICATION_NAME} Assistant."
rewrite "${DESKTOP}/src/gui/assistant/qml/AssistantMessageList.qml" \
    "Start a conversation with Nextcloud Assistant." \
    "Start a conversation with ${APPLICATION_NAME} Assistant."

# --------------------------------------------------------------------------
step "Translations"
# --------------------------------------------------------------------------
# Qt matches a translation by its <source> text, so for the two messages
# rewritten above the <source> has to move with the literal, or the client asks
# for a string no catalogue has and silently falls back to English.
#
# The Client Push link is the same URL in <source> and <translation>, so one
# literal rewrite covers both. The Assistant prompt is not: languages inflect
# "Nextcloud" into the sentence ("Nextcloud-Assistenten", "Nextcloudu"), and
# there is no substitution that stays grammatical. Those bodies are cleared
# instead, which makes Qt fall back to the rebranded source. Everything else
# stays byte-identical.
assistant_src="Start a conversation with ${APPLICATION_NAME} Assistant."
ts_count=0
for ts in "${DESKTOP}"/translations/client_*.ts; do
    [ -f "${ts}" ] || continue
    rewrite_optional "${ts}" \
        "https://github.com/nextcloud/notify_push" "${BRAND_SITE_URL}"
    rewrite_optional "${ts}" \
        "Start a conversation with Nextcloud Assistant." "${assistant_src}"
    # <translation> always follows its <source> on the next line in these files.
    sed -i "\\|<source>${assistant_src}</source>|{n;s|<translation>.*</translation>|<translation type=\"unfinished\"></translation>|}" "${ts}"
    ts_count=$((ts_count + 1))
done
printf '    scanned %s translation catalogues\n' "${ts_count}"

# --------------------------------------------------------------------------
step "House style"
# --------------------------------------------------------------------------
# Style.qml takes its base colour from the wizard header, so the cmake override
# covers nearly all of the QML chrome. The info boxes are the exception: they
# hardcode Nextcloud blue as float components, which would leave Nextcloud-blue
# boxes inside otherwise Gantara-blue windows. Colour only.
brand_rgb() {
    local hex="${BRAND_BACKGROUND_COLOR#\#}"
    printf '%s, %s, %s' \
        "$(awk -v v="$((16#${hex:0:2}))" 'BEGIN{printf "%.3f", v/255}')" \
        "$(awk -v v="$((16#${hex:2:2}))" 'BEGIN{printf "%.3f", v/255}')" \
        "$(awk -v v="$((16#${hex:4:2}))" 'BEGIN{printf "%.3f", v/255}')"
}
BRAND_RGB="$(brand_rgb)"
rewrite "${DESKTOP}/theme/Style/Style.qml" \
    "Qt.rgba(0, 0.51, 0.79, 0.1)" "Qt.rgba(${BRAND_RGB}, 0.1)"
rewrite "${DESKTOP}/theme/Style/Style.qml" \
    "Qt.rgba(0, 0.51, 0.79, 1)" "Qt.rgba(${BRAND_RGB}, 1)"

# --------------------------------------------------------------------------
step "Verifying"
# --------------------------------------------------------------------------
bash "${BRANDING_DIR}/verify-branding.sh" "${DESKTOP}"

printf '\napply-branding: %s branding applied to %s\n' "${APPLICATION_NAME}" "${DESKTOP}"
