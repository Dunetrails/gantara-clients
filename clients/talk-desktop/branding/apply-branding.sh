#!/usr/bin/env bash
#
# Apply Gantara branding to a checked-out nextcloud/talk-desktop source tree.
#
# talk-desktop has a first-class branding mechanism: a `.overrides/build.config.json`
# file that flips the build into "branded" mode (companyName, copyright, app IDs and
# the Windows MSI UpgradeCode are all auto-derived from it). This script drops that
# file in and replaces the brand artwork; the workflow then runs the upstream
# `generate-icons` + `release:package` flow. "Rebasing" onto a new release is a
# one-line tag bump. After staging artwork it also patches a few upstream sources
# for Linux UX (no GitHub Update item, matching WM_CLASS, second launch focuses
# the existing window, no Vue Devtools in packaged builds, AppImage-safe relaunch)
# and Windows packaging (Squirrel icon URL + loading GIF, no Authenticode, no
# auto-update). Linux tray uses a host StatusNotifierItem helper (sni_tray.py) so
# GNOME AppIndicator can see it.
#
# Names: build.config.json `applicationName` ("Dunetrails Talk") stays the app's
# IDENTITY — executable, settings directory (the stored login lives there),
# Squirrel install id and notification AppUserModelId all derive from it, so
# changing it would make every existing install come up as a new, logged-out app.
# What users see comes from `displayName` ("Gantara Talk"): it replaces
# applicationName in the config compiled into the app, and names the Windows
# Start-menu/desktop shortcuts and the Add/Remove Programs entry.
#
# Two kinds of artwork are replaced, all from the Gantara vector logos in assets/
# (copies of k8s-infra-ovh/brand/gantara/logo/svg):
#   1. The six icon SOURCES that scripts/generate-icons.js rasterises into the app
#      and tray icons. These get Talk's OWN treatment: the white North Star on a
#      solid brand-colour rounded tile. That is deliberate — the sync client
#      (clients/desktop) ships the full-colour star on transparency, so the two
#      apps stay tellable apart in the dock, app grid and tray.
#   2. The logos rendered directly by the app UI, which are NOT part of icon-gen:
#        - img/talk-logo.svg            welcome/splash window -> stacked logo, white
#        - img/server-logo-plain.svg    login window          -> horizontal logo, white
#        - img/talk-icon-plain-dark.svg in-app navigation icon -> star, full colour
#      The first two sit on the brand-colour background, where the brand guide asks
#      for the white version; the nav icon sits on a light UI.
#
# NOTE: build.config.json sets primaryColor/backgroundColor to the Gantara colour,
# which flips `withThemingOverrides` on, so the in-app (Talk web UI) theme must be recoloured
# from extracted Nextcloud styles. To avoid a Docker-based extraction on every build, we
# commit the extracted styles under branding/styles/<major>/ (produced by the
# "refresh-talk-styles" workflow) and stage them here; the build then reuses them and skips
# Docker. If none are committed, the build falls back to extracting them itself (needs
# Docker). See ../README.md.
#
# Usage: apply-branding.sh <path-to-talk-desktop-src>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: apply-branding.sh <talk-desktop-src-dir>}"
[ -d "${SRC}" ] || { echo "error: talk-desktop source dir not found: ${SRC}" >&2; exit 1; }

CONFIG="${SCRIPT_DIR}/build.config.json"
ASSETS="${SCRIPT_DIR}/assets"
LOGO="${ASSETS}/logo.png"
STAR_WHITE="${ASSETS}/gantara-symbol-white.svg"
STAR_COLOR="${ASSETS}/gantara-symbol-color.svg"
STACKED_WHITE="${ASSETS}/gantara-stacked-white.svg"
HORIZONTAL_WHITE="${ASSETS}/gantara-horizontal-white.svg"
for f in "${CONFIG}" "${LOGO}" "${STAR_WHITE}" "${STAR_COLOR}" "${STACKED_WHITE}" "${HORIZONTAL_WHITE}"; do
  [ -f "${f}" ] || { echo "error: overlay file missing: ${f}" >&2; exit 1; }
done

IMG="${SRC}/img"
[ -d "${IMG}" ] || { echo "error: img dir missing (tree layout changed?): ${IMG}" >&2; exit 1; }

echo "==> Rebranding '${SRC}' as Gantara Talk"

# 1. Build config -> flips the build into branded mode.
mkdir -p "${SRC}/.overrides"
cp -f "${CONFIG}" "${SRC}/.overrides/build.config.json"
echo "    - installed .overrides/build.config.json"

# 2. Artwork. Every replacement nests one of the Gantara vector logos inside an SVG
#    with the geometry upstream expects, so the upstream pipelines are unchanged.

# Tile colour, read from build.config.json so that stays the single source of truth.
BRAND_COLOR="$(sed -n 's/.*"brandColor"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${CONFIG}" | head -n1)"
[ -n "${BRAND_COLOR}" ] || BRAND_COLOR="#31469D"

# The brand files are one root <svg> line, a <title> and plain paths, so their body
# can be nested as-is (no ids or styles to collide).
svg_viewbox() { tr -d '\r' < "$1" | grep -o 'viewBox="[^"]*"' | head -n1 | sed -e 's/^viewBox="//' -e 's/"$//'; }
svg_body() { tr -d '\r' < "$1" | sed -e '1d' -e '/<\/svg>/d' -e '/<title>/d'; }

# <svg> element placing brand file $1 in the box x=$2 y=$3 w=$4 h=$5, centred.
nested_logo() {
  printf '<svg x="%s" y="%s" width="%s" height="%s" viewBox="%s" preserveAspectRatio="xMidYMid meet">\n%s\n</svg>' \
    "$2" "$3" "$4" "$5" "$(svg_viewbox "$1")" "$(svg_body "$1")"
}

# Square icon sources consumed by scripts/generate-icons.js (fixed 512 box).
# Talk's icon is the white star on a solid brand-colour rounded tile, which is what
# sets it apart from the sync client's full-colour-star-on-transparency icon.
write_icon_svg() { # $1 = output svg path; $2 = margin around the tile in px (default 0)
  local out="$1" m="${2:-0}" side r logo off
  side=$(( 512 - 2 * m ))
  r=$(( side * 22 / 100 ))     # corner radius (~22%, a platform-typical rounded square)
  logo=$(( side * 68 / 100 ))  # star is ~68% of the tile high, leaving optical padding
  off=$(( m + (side - logo) / 2 ))
  cat > "${out}" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" data-brand="gantara" width="512" height="512" viewBox="0 0 512 512">
  <rect x="${m}" y="${m}" width="${side}" height="${side}" rx="${r}" ry="${r}" fill="${BRAND_COLOR}"/>
  $(nested_logo "${STAR_WHITE}" "${off}" "${off}" "${logo}" "${logo}")
</svg>
SVG
}

# UI logos: keep the ORIGINAL viewBox (so the app's layout is unchanged) and fit the
# given brand logo inside it.
write_logo_svg() { # $1 = target svg (read for viewBox, then overwritten); $2 = brand svg
  local target="$1" brand="$2" vb vx vy vw vh
  vb="$(svg_viewbox "${target}" 2>/dev/null || true)"
  [ -n "${vb}" ] || vb="0 0 512 512"
  read -r vx vy vw vh <<<"${vb}"
  cat > "${target}" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" data-brand="gantara" viewBox="${vb}">
  $(nested_logo "${brand}" "${vx}" "${vy}" "${vw}" "${vh}")
</svg>
SVG
}

# 2a. Icon-gen sources (app icon + tray). generate-icons.js rasterises these.
#     "<file>:<tile margin>" — the -spaced/mac sources feed the targets that expect
#     padding around the icon (the Linux app + tray icons, the macOS icon), so their
#     tile is inset; the full-bleed ones are not.
for entry in \
  talk-icon-rounded.svg:0 \
  talk-icon-rounded-spaced.svg:48 \
  talk-icon-mac-shadow.svg:48 \
  talk-icon-plain-light.svg:0 \
  talk-icon-plain-spaced-light.svg:48 \
  talk-icon-plain-spaced-dark.svg:48
do
  svg="${entry%:*}"
  margin="${entry##*:}"
  if [ -f "${IMG}/${svg}" ]; then
    write_icon_svg "${IMG}/${svg}" "${margin}"
    echo "    - replaced img/${svg} (brand tile, margin ${margin})"
  else
    echo "    ! skipped img/${svg} (not present in this release)" >&2
  fi
done

# 2b. Logos rendered directly by the app UI. White versions on the brand-colour
#     welcome/login backgrounds; the nav icon (on light UI) stays full colour.
write_ui_logo() { # $1 = filename under img/, $2 = brand svg
  if [ -f "${IMG}/$1" ]; then
    write_logo_svg "${IMG}/$1" "$2"
    echo "    - replaced img/$1 ($(basename "$2"))"
  else
    echo "    ! skipped img/$1 (not present in this release — UI may show Nextcloud logo)" >&2
  fi
}
write_ui_logo talk-logo.svg "${STACKED_WHITE}"            # welcome / splash window
write_ui_logo server-logo-plain.svg "${HORIZONTAL_WHITE}" # login window
write_ui_logo talk-icon-plain-dark.svg "${STAR_COLOR}"    # in-app Talk navigation-entry icon

# Windows Squirrel setup animation (shown while the unsigned .exe installs).
SQUIRREL_GIF="${SCRIPT_DIR}/assets/squirrel-install-loading.gif"
if [ -f "${SQUIRREL_GIF}" ] && [ -f "${IMG}/squirrel-install-loading.gif" ]; then
  cp -f "${SQUIRREL_GIF}" "${IMG}/squirrel-install-loading.gif"
  echo "    - replaced img/squirrel-install-loading.gif"
elif [ -f "${IMG}/squirrel-install-loading.gif" ]; then
  echo "    ! squirrel-install-loading.gif overlay missing — Windows setup would keep the Nextcloud animation" >&2
fi

# 3. Source string patch: the login screen's server-address field placeholder is a
#    hard-coded 'https://try.nextcloud.com' (not exposed via build.config), so patch it
#    to the Dunetrails tenant-URL pattern. enforceDomain stays false, so the field is
#    still editable — this only changes the grey hint text.
AUTH_VUE="${SRC}/src/authentication/renderer/AuthenticationApp.vue"
PLACEHOLDER="https://<<tenant>>.gantara.eu"
if [ -f "${AUTH_VUE}" ] && grep -q 'https://try\.nextcloud\.com' "${AUTH_VUE}"; then
  sed -i "s#https://try\.nextcloud\.com#${PLACEHOLDER}#g" "${AUTH_VUE}"
  echo "    - patched login placeholder -> ${PLACEHOLDER}"
else
  echo "    ! login placeholder not found in AuthenticationApp.vue (upstream changed?) — skipped" >&2
fi

# 4. Linux launcher / window / updater behaviour. Upstream checks GitHub for
#    Nextcloud Talk releases and treats a second AppImage launch as "a different
#    install" (quit current, spawn new). For the branded client we want:
#      - no Update item in the hamburger (we don't ship Nextcloud's GitHub updater)
#      - one dock/panel identity (Electron WM_CLASS must match dunetrails-talk.desktop)
#      - clicking the desktop/menu item while Talk is open focuses it, rather than
#        closing it (AppImage FUSE mounts differ per launch, so execPath never matches)
#      - skip Vue Devtools in packaged builds (upstream mkdir is not recursive and
#        floods the terminal on first run)
#      - "Restart" actually restarts an AppImage, and a "server was updated" Talk
#        restarts itself once it is hidden in the tray (see the TalkWrapper patch)
#    The tray/status icon stays as upstream (created with the Talk window, hide on
#    close). Linux tray prefers sni_tray.py (Gio StatusNotifierItem + IconPixmap),
#    not Electron Tray, so it does not depend on X11. That needs host python3-gi,
#    which is not everywhere, so a helper that fails to come up falls back to
#    Electron's Tray rather than leaving no icon at all. Spawn must not inherit
#    Electron LD_LIBRARY_PATH. Must match make-appimage.sh (desktop file id).
#    (Electron 43.3-43.4 and 44.0 broke that fallback on GNOME/Cinnamon, electron#52674;
#    fixed in 43.5.0 / 44.1.0, and talk-desktop v2.3+ ships ^44.4, so nothing is pinned.)
LINUX_DESKTOP_ID="dunetrails-talk"
if python3 -c "import sys" >/dev/null 2>&1; then
  PYTHON=(python3)
elif python -c "import sys" >/dev/null 2>&1; then
  PYTHON=(python)
elif py -3 -c "import sys" >/dev/null 2>&1; then
  PYTHON=(py -3)
else
  echo "error: python3 is required to patch talk-desktop sources" >&2
  exit 1
fi
"${PYTHON[@]}" - "${SRC}" "${LINUX_DESKTOP_ID}" <<'PY'
import pathlib
import re
import sys

src = pathlib.Path(sys.argv[1])
desktop_id = sys.argv[2]
failed = False


def patch(rel, pattern, repl, count=1):
    global failed
    path = src / rel
    if not path.is_file():
        print(f"    ! skipped {rel} (not present in this release)", file=sys.stderr)
        failed = True
        return
    text = path.read_text(encoding="utf-8")
    new, n = re.subn(pattern, repl, text, count=count)
    if n == 0:
        print(f"    ! patch did not match {rel} (upstream changed?) — skipped", file=sys.stderr)
        failed = True
        return
    path.write_text(new, encoding="utf-8")
    print(f"    - patched {rel}")


# Hide the hamburger "Update" item: branded builds must not poll nextcloud-releases.
patch(
    "src/app/githubRelease.service.ts",
    r"(export async function checkForUpdate\([^)]*\): Promise<ReleaseInfo \| null> \{)\r?\n",
    r"\1\n\tif (BUILD_CONFIG.isBranded) {\n\t\treturn null\n\t}\n",
)
patch(
    "src/talk/renderer/TitleBar/components/MainMenu.vue",
    r"(onBeforeMount\(async \(\) => \{\r?\n)[ \t]*newRelease\.value = await window\.TALK_DESKTOP\.checkForUpdate\(\)",
    r"\1\tif (BUILD_CONFIG.isBranded) {\n\t\treturn\n\t}\n\tnewRelease.value = await window.TALK_DESKTOP.checkForUpdate()",
)

# Do not pre-fill the login field with BUILD_CONFIG.domain (that value exists so
# app IDs become com.dunetrails.* rather than com.nextcloud.*). Tenants live on
# <name>.gantara.eu; the placeholder is the only hint unless enforceDomain.
patch(
    "src/authentication/renderer/AuthenticationApp.vue",
    r"const rawServerUrl = ref\(BUILD_CONFIG\.domain \?\? prefilledServer\)",
    "const rawServerUrl = ref(BUILD_CONFIG.enforceDomain && BUILD_CONFIG.domain"
    " ? BUILD_CONFIG.domain : (prefilledServer ?? ''))",
)

# About dialog: Issues / Source Code point at github.com/nextcloud. Hide them
# in branded builds (same as the Help menu in app.menu.js).
patch(
    "src/help/renderer/HelpApp.vue",
    r'(<a :href="packageInfo\.bugs\.url"[\s\S]*?</a>\s*\|\s*<a :href="packageInfo\.repository"[\s\S]*?</a>)',
    r'<template v-if="!BUILD_CONFIG.isBranded">\1</template>',
)

# Squirrel.Windows downloads iconUrl for Add/Remove Programs. Upstream hard-codes
# the Nextcloud Talk .ico on GitHub; point it at our domain instead.
patch(
    "forge.config.js",
    r"iconUrl:\s*'https://raw\.githubusercontent\.com/nextcloud/talk-desktop[^']*'",
    "iconUrl: 'https://gantara.eu/talk-desktop/icon.ico'",
)

# Electron 41 uses package.json desktopName as XDG app id / WM_CLASS. Upstream is
# com.nextcloud.talk.desktop; our .desktop is {desktop_id}.desktop. Mismatch makes
# GNOME/KDE show a second ungrouped icon while the app is running.
patch(
    "package.json",
    r'"desktopName":\s*"[^"]*"',
    '"desktopName": "%s"' % desktop_id,
)
patch(
    "package.json",
    r'"productName":\s*"Nextcloud Talk"',
    '"productName": "Dunetrails Talk"',
)
# Display name: the config compiled into the app (title bar, window titles, login,
# About, tray tooltip, the device name the server lists) says displayName, while
# forge.config.js keeps building the executable/install identity from applicationName.
DISPLAY_CONFIG = r"\1(({ displayName, ...c }) => ({ ...c, applicationName: displayName || c.applicationName }))(\2)\3"
patch(
    "webpack.main.config.js",
    r"(__BUILD_CONFIG__: JSON\.stringify\()(resolveBuildConfig\(\))(\))",
    DISPLAY_CONFIG,
)
patch(
    "webpack.renderer.config.js",
    r"(__BUILD_CONFIG__: JSON\.stringify\()(BUILD_CONFIG)(\))",
    DISPLAY_CONFIG,
)
# app.name is the tray tooltip and the Linux notification sender, but upstream also
# derives the settings directory from it on the line before; rename only afterwards.
patch(
    "src/main.js",
    r"(app\.setPath\('userData', path\.join\(app\.getPath\('appData'\), app\.getName\(\)\)\)\r?\n)",
    r"\1app.setName(BUILD_CONFIG.applicationName)\n",
)
# Windows: Squirrel names shortcuts Programs\<CompanyName>\<ProductName>.lnk and
# Desktop\<ProductName>.lnk from the exe metadata, and the Add/Remove Programs entry
# from the package title. The exe name itself stays, so install id and
# AppUserModelId do not change.
patch(
    "forge.config.js",
    r"(win32metadata: \{\r?\n)([ \t]*)CompanyName: BUILD_CONFIG\.companyName,",
    r"\1\2CompanyName: BUILD_CONFIG.vendorName || BUILD_CONFIG.companyName,\n"
    r"\2ProductName: BUILD_CONFIG.displayName || BUILD_CONFIG.applicationName,\n"
    r"\2FileDescription: BUILD_CONFIG.displayName || BUILD_CONFIG.applicationName,",
)
patch(
    "forge.config.js",
    r"(// Meta\r?\n[ \t]*)title: BUILD_CONFIG\.applicationName,",
    r"\1title: BUILD_CONFIG.displayName || BUILD_CONFIG.applicationName,",
)
# On update Squirrel only creates the shortcuts under the new names; the ones the
# Dunetrails-named builds created would stay behind next to them.
patch(
    "src/main.js",
    r"(if \(require\('electron-squirrel-startup'\)\) \{)",
    "if (process.platform === 'win32' && process.argv[1] === '--squirrel-updated') {\n"
    "\tconst fs = require('node:fs')\n"
    "\tconst programs = path.join(process.env.APPDATA || '', 'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Dunetrails Talk')\n"
    "\tfor (const shortcut of [path.join(programs, 'Dunetrails Talk.lnk'), path.join(app.getPath('desktop'), 'Dunetrails Talk.lnk')]) {\n"
    "\t\tfs.rmSync(shortcut, { force: true })\n"
    "\t}\n"
    "\ttry {\n"
    "\t\tfs.rmdirSync(programs)\n"
    "\t} catch {\n"
    "\t\t// not empty or not there\n"
    "\t}\n"
    "}\n\n"
    r"\1",
)

# Relaunch. app.relaunch() re-executes process.execPath, which for an AppImage is
# on the per-launch FUSE mount that disappears when this process exits, so the
# "Restart" button just quit. Relaunch the AppImage file instead. `background`
# restarts without showing the Talk window (upstream's --background flag).
patch(
    "src/app/system.utils.ts",
    r"export function relaunchApp\(\) \{(?:\r?\n[ \t]*//[^\n]*)*\r?\n[ \t]*app\.relaunch\(\{ args: process\.argv\.slice\(1\) \}\)",
    "export function relaunchApp({ background = false }: { background?: boolean } = {}) {\n"
    "\tconst args = process.argv.slice(1).filter((arg) => arg !== '--background')\n"
    "\tif (background) {\n"
    "\t\targs.push('--background')\n"
    "\t}\n"
    "\t// Flatpak only relaunches with explicitly passed args\n"
    "\tapp.relaunch(process.env.APPIMAGE ? { execPath: process.env.APPIMAGE, args } : { args })",
)
patch(
    "src/preload.js",
    r"relaunch: \(\) => ipcRenderer\.send\('app:relaunch'\),",
    "relaunch: (options) => ipcRenderer.send('app:relaunch', options),",
)
patch(
    "src/main.js",
    r"ipcMain\.on\('app:relaunch', \(\) => relaunchApp\(\)\)",
    "ipcMain.on('app:relaunch', (event, options) => {\n"
    "\tif (options?.ifHidden && require('electron').BrowserWindow.fromWebContents(event.sender)?.isVisible()) {\n"
    "\t\treturn\n"
    "\t}\n"
    "\trelaunchApp(options)\n"
    "})",
)
# "The server was updated. Please restart the app." Talk raises this whenever the
# server's Talk hash changes (a Talk update, but also any theming or Talk setting
# change). The window hides to the tray instead of quitting, so a Talk that lives
# in the tray for days would never restart and keep the warning up. Once the flag
# is set, restart in the background as soon as the window is out of sight and no
# call is running; the restart re-fetches capabilities, which clears the flag.
patch(
    "src/talk/renderer/TalkWrapper/TalkWrapper.vue",
    r"(onTalkHashDirty\(\(\) => \{\r?\n[ \t]*appData\.setTalkHashDirty\(true\)\.persist\(\)\r?\n)",
    r"\1\t\trelaunchOnceHidden()\n",
)
patch(
    "src/talk/renderer/TalkWrapper/TalkWrapper.vue",
    r"(\r?\nonMounted\(async \(\) => \{)",
    "\n"
    "/**\n"
    " * Restart in the background once the window is hidden and no call is running\n"
    " */\n"
    "function relaunchOnceHidden() {\n"
    "\tconst isInAnyCall = () => {\n"
    "\t\tconst state = window.OCA?.Talk?.instance?.$store?.state?.participantsStore\n"
    "\t\treturn [state?.inCall, state?.joiningCall]\n"
    "\t\t\t.some((calls) => Object.values(calls ?? {}).some((sessions) => Object.keys(sessions ?? {}).length > 0))\n"
    "\t}\n"
    "\t// The main process checks the window is really hidden (not just minimised)\n"
    "\tconst check = () => {\n"
    "\t\tif (!isInAnyCall()) {\n"
    "\t\t\twindow.TALK_DESKTOP.relaunch({ background: true, ifHidden: true })\n"
    "\t\t}\n"
    "\t}\n"
    "\tdocument.addEventListener('visibilitychange', check)\n"
    "\t// A call can end while the window is already hidden\n"
    "\tsetInterval(check, 60_000)\n"
    "\tcheck()\n"
    "}\n"
    r"\1",
)

patch(
    "src/main.js",
    r"(app\.setName\(APP_NAME\)\r?\n)",
    r"\1if (process.platform === 'linux') {\n"
    r"\tconst tmp = process.env.TMPDIR || ''\n"
    r"\tconst appdir = process.env.APPDIR || ''\n"
    r"\tif (!tmp || tmp.includes('/.mount_') || (appdir && tmp.startsWith(appdir))) {\n"
    r"\t\tprocess.env.TMPDIR = '/tmp'\n"
    r"\t}\n"
    r"\tapp.setDesktopName('%s')\n"
    r"\tapp.commandLine.appendSwitch('class', '%s')\n"
    r"\tapp.commandLine.appendSwitch('disable-features', 'Vulkan')\n"
    r"}\n" % (desktop_id, desktop_id),
)

# Packaged AppImage: do not unpack Vue Devtools into ~/.config (dev-only; mkdir is not recursive).
patch(
    "src/main.js",
    r"try \{\r?\n[ \t]*await installVueDevtools\(\)\r?\n[ \t]*\} catch \(error\) \{",
    "try {\n\t\tif (!app.isPackaged) {\n\t\t\tawait installVueDevtools()\n\t\t}\n\t} catch (error) {",
)

# Second launch on Linux: always focus. AppImage mounts are unique per process, so
# isSameExecution() is false and upstream quits the running app to "switch install".
patch(
    "src/main.js",
    r"if \(isSameExecution\(argv\[0\], cwd\)\) \{\r?\n[ \t]*focusMainWindow\(\)",
    "if (process.platform === 'linux' || isSameExecution(argv[0], cwd)) {\n\t\t\tfocusMainWindow()",
)

# Keep the Tray object alive (GC would drop the icon). On Linux, prefer our
# StatusNotifierItem helper (IconPixmap on the unique bus name) because Electron
# 43.3+ GNOME AppIndicator cannot read Chromium's multiplexer.
patch(
    "src/app/app.tray.js",
    r"let isAppQuitting = false",
    "let isAppQuitting = false\n\n"
    "// Module scope so GC cannot drop the icon, and so the Linux fallback below\n"
    "// can still build a Tray after setupTray() has already returned.\n"
    "let tray = null\n"
    "let linuxSniTrayGaveUp = false\n"
    "let hideOnCloseBound = false",
)
# Replace setupTray wholesale rather than splicing the Linux branch into it: the
# Electron Tray now has to be reachable a second time, because the SNI helper is
# only known to have failed (host has no python3-gi, import error, immediate
# exit) after spawn() has already returned a live child object. Without that
# fallback a helper that dies leaves the app with no tray icon at all — worse
# than upstream, which at least tries Chromium's own StatusNotifier.
patch(
    "src/app/app.tray.js",
    r"(?s)function setupTray\(browserWindow\) \{.*?\n\treturn tray\n\}",
    "function setupTray(browserWindow) {\n"
    "\tlet sniTray = null\n"
    "\tif (process.platform === 'linux' && !linuxSniTrayGaveUp) {\n"
    "\t\ttry {\n"
    "\t\t\tconst { setupLinuxSniTray } = require('./linux-sni-tray.js')\n"
    "\t\t\tsniTray = setupLinuxSniTray(browserWindow, () => {\n"
    "\t\t\t\tlinuxSniTrayGaveUp = true\n"
    "\t\t\t\tsetupTray(browserWindow)\n"
    "\t\t\t})\n"
    "\t\t} catch (error) {\n"
    "\t\t\tconsole.error('Linux SNI tray failed', error)\n"
    "\t\t}\n"
    "\t}\n"
    "\n"
    "\tif (!sniTray && !browserWindow.isDestroyed()) {\n"
    "\t\tconst showWindow = () => {\n"
    "\t\t\tif (!browserWindow.isDestroyed()) {\n"
    "\t\t\t\tbrowserWindow.show()\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "\t\ttray = new Tray(path.join(app.getAppPath(), '.webpack/main', getTrayIcon()))\n"
    "\t\ttray.setToolTip(app.name)\n"
    "\t\ttray.setContextMenu(Menu.buildFromTemplate([\n"
    "\t\t\t{\n"
    "\t\t\t\tlabel: 'Open',\n"
    "\t\t\t\tclick: showWindow,\n"
    "\t\t\t},\n"
    "\t\t\t{\n"
    "\t\t\t\trole: 'quit',\n"
    "\t\t\t},\n"
    "\t\t]))\n"
    "\t\ttray.on('click', showWindow)\n"
    "\t}\n"
    "\n"
    "\tif (!hideOnCloseBound) {\n"
    "\t\thideOnCloseBound = true\n"
    "\t\tbrowserWindow.on('close', (event) => {\n"
    "\t\t\tif (!isAppQuitting) {\n"
    "\t\t\t\tevent.preventDefault()\n"
    "\t\t\t\tbrowserWindow.hide()\n"
    "\t\t\t}\n"
    "\t\t})\n"
    "\t\tbrowserWindow.on('closed', () => {\n"
    "\t\t\tif (tray) {\n"
    "\t\t\t\ttray.destroy()\n"
    "\t\t\t\ttray = null\n"
    "\t\t\t}\n"
    "\t\t})\n"
    "\t}\n"
    "\n"
    "\treturn sniTray || tray\n"
    "}",
)

# AppImage FUSE paths: /tmp/.mount_* differs per launch even for the same file.
patch(
    "src/app/system.utils.ts",
    r"const execPath = path\.isAbsolute\(argv0\) \? argv0 : path\.resolve\(cwd, argv0\)\r?\n\r?\n[ \t]*return execPath === process\.execPath",
    "const execPath = path.isAbsolute(argv0) ? argv0 : path.resolve(cwd, argv0)\n\n"
    "\tif (execPath === process.execPath) {\n"
    "\t\treturn true\n"
    "\t}\n\n"
    "\t// AppImage: each launch gets a unique FUSE mount (/tmp/.mount_*), so the full\n"
    "\t// execPath never matches. Same binary name = same app.\n"
    "\tif (execPath.includes(`${path.sep}.mount_`) || process.execPath.includes(`${path.sep}.mount_`)) {\n"
    "\t\treturn path.basename(execPath) === path.basename(process.execPath)\n"
    "\t}\n\n"
    "\treturn false",
)

sys.exit(1 if failed else 0)
PY

mkdir -p "${SRC}/src/app"
cp -f "${SCRIPT_DIR}/linux-sni-tray.js" "${SRC}/src/app/linux-sni-tray.js"
cp -f "${SCRIPT_DIR}/sni_tray.py" "${SRC}/src/app/sni_tray.py"
echo "    - installed src/app/linux-sni-tray.js and sni_tray.py"

# 5. Pre-generated themed styles. If we've committed extracted Nextcloud styles under
#    branding/styles/<major>/, stage them into .overrides/styles/ so the build reuses them
#    and SKIPS the Docker-based extraction. Produced by the "refresh-talk-styles" workflow.
#    If absent, the build falls back to extracting via Docker (still correct, just slower).
STYLES_SRC="${SCRIPT_DIR}/styles"
if [ -d "${STYLES_SRC}" ] && [ -n "$(ls -A "${STYLES_SRC}" 2>/dev/null)" ]; then
  mkdir -p "${SRC}/.overrides/styles"
  cp -r "${STYLES_SRC}/." "${SRC}/.overrides/styles/"
  echo "    - staged pre-generated theme styles for major(s): $(ls "${STYLES_SRC}" | tr '\n' ' ')"
  # Extracted Nextcloud styles still ship the cloud wordmark. Replace it so the
  # in-app Talk UI cannot render a Nextcloud logo. refresh-talk-styles will
  # bring the upstream files back; this rewrite always runs after staging.
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    case "${f}" in
      *.svg)
        write_logo_svg "${f}" "${STAR_WHITE}"
        echo "    - replaced ${f#"${SRC}"/} (white Gantara star)"
        ;;
      *.png)
        cp -f "${LOGO}" "${f}"
        echo "    - replaced ${f#"${SRC}"/}"
        ;;
    esac
  done <<EOF
$(find "${SRC}/.overrides/styles" -type f \( \
  -name 'logo.svg' -o -name 'logo.png' -o \
  -name 'logo-enterprise.svg' -o -name 'logo-enterprise.png' -o \
  -name 'logo-icon-*.png' -o -name 'logo-mail.png' \) 2>/dev/null)
EOF
else
  echo "    - no pre-generated theme styles committed; build will extract them via Docker" >&2
fi

echo "==> Branding files staged. Run 'npm run generate-icons' then the release build."
