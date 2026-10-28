#!/usr/bin/env bash
#
# Wrap the electron-forge-packaged Talk-desktop app tree into a single-file,
# double-clickable Linux AppImage.
#
# `npm run release:package -- --linux` (run by the workflow) leaves a fully
# packaged app directory at out/<AppName>-linux-<arch>/. Rather than teach the
# upstream tree an AppImage maker (extra deps, gated behind build.config.json),
# we take that finished directory and assemble an AppImage around it here, as a
# decoupled post-build step. This keeps our "overlay, don't fork" approach.
#
# Usage: make-appimage.sh <talk-desktop-src-dir> [output-dir]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: make-appimage.sh <talk-desktop-src-dir> [out-dir]}"
OUT_DIR="${2:-${SRC}/out/appimage}"
# Menu/dock icon. Prefer the icon generate-icons rasterised from our branded source
# (512px, from talk-icon-rounded-spaced.svg): that is the brand-colour tile that keeps
# Talk distinguishable from the sync client, so the AppImage's menu entry matches the
# running app. Fall back to the raw brand mark if the build left no generated icon.
LOGO="${SRC}/img/icons/icon.png"
[ -f "${LOGO}" ] || LOGO="${SCRIPT_DIR}/assets/logo.png"

# Shown in the menu. The desktop id, icon name and WM class below stay
# dunetrails-talk: they are identities existing installs and the running window use.
APP_NAME="Gantara Talk"
ARCH="${ARCH:-x86_64}"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"

[ -f "${LOGO}" ] || { echo "error: no icon found (${SRC}/img/icons/icon.png or ${SCRIPT_DIR}/assets/logo.png)" >&2; exit 1; }
echo "==> menu icon: ${LOGO}"

# 1. Locate the packaged app dir electron-forge left behind (out/<name>-linux-<arch>).
#    Fall back to extracting the maker .zip if the dir was cleaned away.
PKG_DIR=""
for d in "${SRC}"/out/*-linux-*; do
  [ -d "${d}" ] && PKG_DIR="${d}" && break
done
if [ -z "${PKG_DIR}" ]; then
  ZIP="$(find "${SRC}/out/make" -name '*.zip' -print -quit 2>/dev/null || true)"
  [ -n "${ZIP}" ] || { echo "error: no packaged dir or .zip under ${SRC}/out" >&2; exit 1; }
  echo "==> no packaged dir; extracting ${ZIP}"
  EXTRACT="$(mktemp -d)"
  unzip -q "${ZIP}" -d "${EXTRACT}"
  PKG_DIR="$(find "${EXTRACT}" -maxdepth 1 -type d -name '*-linux-*' -print -quit)"
  [ -n "${PKG_DIR}" ] || PKG_DIR="${EXTRACT}"
fi
echo "==> packaged app dir: ${PKG_DIR}"

# 2. Identify the main Electron binary: the executable at the tree root that is
#    neither a shared lib nor one of Chromium's helper binaries.
MAIN_BIN="$(find "${PKG_DIR}" -maxdepth 1 -type f -executable \
  ! -name 'chrome-sandbox' ! -name 'chrome_crashpad_handler' \
  ! -name '*.so' ! -name '*.so.*' -printf '%f\n' | head -n1)"
[ -n "${MAIN_BIN}" ] || { echo "error: could not locate main binary in ${PKG_DIR}" >&2; exit 1; }
echo "==> main binary: ${MAIN_BIN}"

# 3. Assemble the AppDir: the whole packaged tree at root, plus the AppImage
#    metadata (AppRun, top-level .desktop, top-level icon) appimagetool requires.
APPROOT="$(mktemp -d)"
APPDIR="${APPROOT}/AppDir"
mkdir -p "${APPDIR}"
cp -a "${PKG_DIR}/." "${APPDIR}/"

cp -f "${LOGO}" "${APPDIR}/dunetrails-talk.png"
install -Dm644 "${LOGO}" "${APPDIR}/usr/share/icons/hicolor/512x512/apps/dunetrails-talk.png"

# Quote MAIN_BIN if it contains spaces (Electron often names it "Dunetrails Talk").
# Unquoted Exec=Dunetrails Talk %U is invalid and poisons any later desktop rewrite
# that strips only the first token. (Avoid a ' inside a [...] case pattern — it
# opens a single-quoted string and breaks the rest of this script.)
case "${MAIN_BIN}" in
  *" "*) MAIN_EXEC="\"${MAIN_BIN}\"" ;;
  *)     MAIN_EXEC="${MAIN_BIN}" ;;
esac
# StartupWMClass must match Electron's Linux WM_CLASS / XDG app id (package.json
# desktopName + app.setDesktopName in apply-branding.sh). Using the Name string
# ("Dunetrails Talk") made GNOME/KDE treat the running window as a second icon.
cat > "${APPDIR}/dunetrails-talk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=${MAIN_EXEC} %U
Icon=dunetrails-talk
Categories=Network;Chat;InstantMessaging;
Comment=Gantara Talk desktop client
Terminal=false
StartupNotify=true
StartupWMClass=dunetrails-talk
EOF

# AppRun launches the bundled Electron binary. --no-sandbox: an AppImage is a
# read-only FUSE mount, so the SUID chrome-sandbox helper can't be used; disabling
# the setuid sandbox is the portable way to launch (acceptable for a trusted,
# internally-distributed build). Disable Vulkan so Wayland can still map a
# window. Do NOT force ozone x11: that switches GNOME from the .desktop app id
# (dunetrails-talk) to an X11 WM_CLASS that does not match, so the dock grows a
# second ungrouped icon. --class keeps X11 sessions grouped if they stay on xcb.
cat > "${APPDIR}/AppRun" <<EOF
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
# Tray PNGs live under TMPDIR and must be readable by gnome-shell/plasmashell.
# Never leave TMPDIR on the FUSE mount; prefer host /tmp over XDG_RUNTIME_DIR.
case "\${TMPDIR:-}" in
  /tmp/.mount_*|"\$HERE"*) unset TMPDIR ;;
esac
export TMPDIR=/tmp
exec "\${HERE}/${MAIN_BIN}" --no-sandbox --class=dunetrails-talk --disable-features=Vulkan "\$@"
EOF
chmod +x "${APPDIR}/AppRun"

# Host-side StatusNotifierItem helper (GNOME AppIndicator talks to the unique
# bus name; Electron's Chromium tray multiplexer does not answer that).
cp -f "${SCRIPT_DIR}/sni_tray.py" "${APPDIR}/sni_tray.py"
mkdir -p "${APPDIR}/resources"
cp -f "${SCRIPT_DIR}/sni_tray.py" "${APPDIR}/resources/sni_tray.py"

# 4. Build the single-file AppImage. --appimage-extract-and-run avoids needing
#    FUSE (unavailable on most CI runners) for appimagetool itself.
mkdir -p "${OUT_DIR}"
TOOL="$(mktemp -d)/appimagetool.AppImage"
echo "==> fetching appimagetool"
wget -qO "${TOOL}" "${APPIMAGETOOL_URL}"
chmod +x "${TOOL}"

OUTFILE="${OUT_DIR}/Gantara_Talk-${ARCH}.AppImage"
ARCH="${ARCH}" "${TOOL}" --appimage-extract-and-run "${APPDIR}" "${OUTFILE}"
echo "==> built ${OUTFILE}"
