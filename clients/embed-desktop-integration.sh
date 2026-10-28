#!/usr/bin/env bash
#
# Make a Dunetrails AppImage integrate itself into the Linux applications menu
# on first launch — no separate installer, no AppImageLauncher.
#
# A plain AppImage never registers a launcher, so it doesn't appear in the
# applications menu / "programs" list until something creates a .desktop entry.
# This is a BUILD-TIME post-processing step that injects a small self-integrating
# AppRun wrapper into a finished AppImage, so at RUNTIME the app registers itself
# the first time a user starts it (using the .desktop + icon already embedded in
# the AppImage, and $APPIMAGE — the path the AppImage runtime exports for the
# file itself). The sync client also gets an XDG autostart entry so it launches
# at login (Exec=$APPIMAGE --background). Users can opt out with DUNETRAILS_INTEGRATE=0.
#
# It works for BOTH clients uniformly, including the sync client whose AppRun is
# produced by upstream's linuxdeployqt (which we don't control): we rename that
# AppRun to AppRun.orig and chain-load it after integrating.
#
# Usage: embed-desktop-integration.sh <in.AppImage> [out.AppImage]
#        (out defaults to in-place)
#
# Env:
#   EXTRA_QT_PLUGIN_DIRS  whitespace-separated Qt plugin directories to fold into
#                   the AppDir while it is unpacked here. linuxdeploy-plugin-qt
#                   deploys the wayland platform plugin along with the decoration
#                   and shell integrations, but not
#                   wayland-graphics-integration-client -- and without that,
#                   Qt Quick has no client-side EGL buffer integration and a
#                   Wayland session gets a client with no windows. Since this is
#                   the step that already unpacks and repacks, it is also the
#                   cheapest place to complete the deployment.
#   AUTOSTART_NAME  basename of the XDG autostart entry, WITHOUT ".desktop".
#                   Must equal the sync client's APPLICATION_SHORTNAME: Qt looks
#                   for ~/.config/autostart/<APPLICATION_SHORTNAME>.desktop in
#                   Utility::hasLaunchOnStartup(), and that is NOT the same as
#                   the .desktop "Name=" (upstream ships "<brand> Desktop").
#                   Get it wrong and the in-app "Launch on system startup"
#                   checkbox reads/writes a different file than the one we
#                   wrote, so unticking it does not stop the autostart.
#
set -euo pipefail

SRC="${1:?usage: embed-desktop-integration.sh <in.AppImage> [out.AppImage]}"
SRC="$(readlink -f "${SRC}")"
OUT="${2:-${SRC}}"
ARCH="${ARCH:-x86_64}"
AUTOSTART_NAME="${AUTOSTART_NAME:-}"
EXTRA_QT_PLUGIN_DIRS="${EXTRA_QT_PLUGIN_DIRS:-}"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${ARCH}.AppImage"

[ -f "${SRC}" ] || { echo "error: not found: ${SRC}" >&2; exit 1; }
chmod +x "${SRC}" 2>/dev/null || true

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# 1. Unpack the finished AppImage (no FUSE: the runtime's own extractor).
( cd "${WORK}" && "${SRC}" --appimage-extract >/dev/null )
APPDIR="${WORK}/squashfs-root"
[ -d "${APPDIR}" ] || { echo "error: extraction produced no squashfs-root" >&2; exit 1; }
[ -e "${APPDIR}/AppRun" ] || { echo "error: no AppRun in ${SRC}" >&2; exit 1; }

# 1b. Complete the Qt deployment where linuxdeploy stopped short (see the env
#     notes at the top). The plugins are copied verbatim: their rpath already
#     starts with $ORIGIN/../../lib, so they resolve against the AppDir's own
#     libraries once they sit under usr/plugins/.
if [ -n "${EXTRA_QT_PLUGIN_DIRS}" ]; then
  [ -d "${APPDIR}/usr/plugins" ] || { echo "error: no usr/plugins in ${SRC}; is this a Qt AppImage?" >&2; exit 1; }
  for pdir in ${EXTRA_QT_PLUGIN_DIRS}; do
    [ -d "${pdir}" ] || { echo "error: extra Qt plugin dir not found: ${pdir}" >&2; exit 1; }
    cp -r "${pdir}" "${APPDIR}/usr/plugins/"
    echo "==> bundled Qt plugins from ${pdir}"
  done
fi

# 2. Preserve the real entrypoint and drop our wrapper in front of it. The
#    wrapper reads the embedded .desktop/icon at runtime, so the body is a
#    quoted heredoc; only AUTOSTART_NAME is baked in, as a leading assignment.
mv -f "${APPDIR}/AppRun" "${APPDIR}/AppRun.orig"

# Single-quote for /bin/sh so a brand name with spaces survives.
sh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

{
printf '%s\n' '#!/bin/sh'
printf 'DUNETRAILS_AUTOSTART_BASENAME=%s\n' "$(sh_quote "${AUTOSTART_NAME}")"
cat <<'APPRUN'
# Dunetrails self-integrating AppRun (injected by embed-desktop-integration.sh).
# First run as an AppImage: register a menu entry pointing at this AppImage so it
# shows up in the applications list without a separate install. Reuses the
# .desktop + icon embedded here. Opt out with DUNETRAILS_INTEGRATE=0.
HERE="$(dirname "$(readlink -f "$0")")"

# Chromium (Talk) writes the StatusNotifier tray PNG under TMPDIR. The AppImage
# runtime often sets TMPDIR to the FUSE mount; gnome-shell/plasmashell cannot
# read that, so the window runs with no tray icon. Use host /tmp (not
# XDG_RUNTIME_DIR: some gnome-shell sandboxes cannot follow /run/user).
case "${TMPDIR:-}" in
  /tmp/.mount_*|"$HERE"*) unset TMPDIR ;;
esac
if [ -z "${TMPDIR:-}" ] || [ ! -w "${TMPDIR}" ]; then
  export TMPDIR=/tmp
fi

if [ -n "${APPIMAGE:-}" ] && [ "${DUNETRAILS_INTEGRATE:-1}" = "1" ]; then
  ( # best-effort, never block launch
    schema=11  # bump when this integration logic changes, to force a one-time refresh
    src="$(ls "$HERE"/*.desktop 2>/dev/null | head -n1)"
    [ -n "$src" ] || exit 0
    id="$(basename "$src" .desktop)"
    apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    dest="$apps/$id.desktop"
    stamp="$apps/.$id.appimage-path"
    # Skip only if already integrated for this exact AppImage + schema.
    if [ -f "$dest" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$schema $APPIMAGE" ]; then exit 0; fi
    icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
    mkdir -p "$apps" "$icons"
    iname="$(sed -n 's/^Icon=//p' "$src" | head -n1)"; [ -n "$iname" ] || iname="$id"
    isrc="$(find "$HERE/usr/share/icons" -type f -name "$iname.png" 2>/dev/null | sort -t/ -k7 -rn | head -n1)"
    [ -n "$isrc" ] || isrc="$HERE/$iname.png"
    if [ -f "$isrc" ]; then
      cp -f "$isrc" "$icons/$id.png" 2>/dev/null || true
      # Autostart / Qt use Icon=<APPLICATION_ICON_NAME> (e.g. Dunetrails), not the reverse-DNS id.
      [ "$iname" != "$id" ] && cp -f "$isrc" "$icons/$iname.png" 2>/dev/null || true
    fi
    # Build a clean, single-group [Desktop Entry]. NEVER reuse the embedded Exec
    # argv: Electron binaries are often named "Dunetrails Talk" (with a space), so
    # stripping only the first Exec= token leaves a stray "Talk" argument and the
    # menu/dock launch fails silently. Always invoke the AppImage itself + %U.
    # Sync client's upstream .desktop also has a [Desktop Action Quit] group and no
    # StartupWMClass — we drop actions and set WMClass so the dock can focus/launch.
    name="$(sed -n 's/^Name=//p' "$src" | head -n1)"; [ -n "$name" ] || name="$id"
    comment="$(sed -n 's/^Comment=//p' "$src" | head -n1)"
    categories="$(sed -n 's/^Categories=//p' "$src" | head -n1)"; [ -n "$categories" ] || categories="Utility;"
    # Keep MimeType: the client registers itself as the x-scheme-handler for the
    # server's "Edit locally" links (Utility::registerUriHandlerForLocalEditing
    # runs xdg-mime against this very file), and xdg-open only resolves the
    # handler if the entry declares the type.
    mimetype="$(sed -n 's/^MimeType=//p' "$src" | head -n1)"
    wmclass="$(sed -n 's/^StartupWMClass=//p' "$src" | head -n1)"
    # Prefer the binary basename (Qt WM_CLASS) when upstream omitted StartupWMClass.
    [ -n "$wmclass" ] || wmclass="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$src" | head -n1 | tr -d '\"')"
    [ -n "$wmclass" ] || wmclass="$name"
    # Quote only when the path has spaces (avoid ' inside [...] — breaks sh parsing).
    case "$APPIMAGE" in
      *" "*) exec_path="\"$APPIMAGE\"" ;;
      *)     exec_path="$APPIMAGE" ;;
    esac
    {
      echo "[Desktop Entry]"
      echo "Type=Application"
      echo "Version=1.0"
      echo "Name=$name"
      [ -n "$comment" ] && echo "Comment=$comment"
      echo "Exec=$exec_path %U"
      echo "TryExec=$APPIMAGE"
      echo "Icon=$id"
      echo "Terminal=false"
      echo "StartupNotify=false"
      echo "Categories=$categories"
      [ -n "$mimetype" ] && echo "MimeType=$mimetype"
      echo "StartupWMClass=$wmclass"
      echo "SingleMainWindow=true"
    } > "$dest" 2>/dev/null
    chmod +x "$dest" 2>/dev/null || true
    # Sync client: XDG autostart so it comes up at login. Qt writes
    # ~/.config/autostart/<APPLICATION_SHORTNAME>.desktop, but if APPIMAGE isn't
    # visible it records Exec=/tmp/.mount_*/usr/bin/dunetrails — gone after
    # logout. We know $APPIMAGE here. Skip Talk.
    case "$id" in
      *[Tt]alk*) ;;
      *)
        adir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
        mkdir -p "$adir"
        # The basename MUST be APPLICATION_SHORTNAME, which is what
        # Utility::hasLaunchOnStartup()/setLaunchOnStartup() use. It is NOT the
        # .desktop Name= — upstream mirall.desktop.in ships "<brand> Desktop".
        # Using Name= here writes a second, invisible autostart entry: the
        # settings checkbox then reads the wrong file, and unticking it removes
        # <shortname>.desktop while ours keeps starting the client anyway.
        aname="${DUNETRAILS_AUTOSTART_BASENAME:-}"
        [ -n "$aname" ] || aname="$iname"
        af="$adir/$aname.desktop"
        # Clean up entries older builds wrote under the Name= basename.
        [ "$name" != "$aname" ] && rm -f "$adir/$name.desktop" 2>/dev/null
        {
          echo "[Desktop Entry]"
          echo "Name=$name"
          echo "GenericName=File Synchronizer"
          echo "Exec=$exec_path --background"
          echo "Terminal=false"
          echo "Icon=$iname"
          echo "Categories=Network"
          echo "Type=Application"
          echo "StartupNotify=false"
          echo "X-GNOME-Autostart-enabled=true"
          echo "X-GNOME-Autostart-Delay=10"
        } > "$af" 2>/dev/null
        chmod +x "$af" 2>/dev/null || true
        ;;
    esac
    printf '%s %s\n' "$schema" "$APPIMAGE" > "$stamp" 2>/dev/null || true
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps" >/dev/null 2>&1 || true
  ) 2>/dev/null || true
fi

# Electron Talk: stay in-process. Backgrounding AppRun lets the AppImage runtime
# tear down the FUSE mount (file-manager "Run" / "Run in Terminal" then looks
# like a double-click that does nothing). Do not force ozone x11 here: that
# ungroups the GNOME dock icon from dunetrails-talk.desktop.
if [ -e "$HERE/chrome_crashpad_handler" ] || [ -e "$HERE/chrome-sandbox" ]; then
  exec "$HERE/AppRun.orig" "$@"
fi

# linuxdeploy ships xcb, not wayland. A Wayland session still asks Qt for
# "wayland" (XDG_SESSION_TYPE and sometimes QT_QPA_PLATFORM=wayland). Qt then
# prints "Could not find the Qt platform plugin wayland" and keeps the GUI
# attached to the terminal, which looks like a hung install even though the
# tray is up. Force xcb unless this AppImage actually bundled wayland. The
# plugin is libqwayland-generic.so / libqwayland-egl.so — never a bare
# libqwayland.so, so match with a glob.
qt_has_wayland=0
for p in "$HERE"/usr/plugins/platforms/libqwayland*.so "$HERE"/plugins/platforms/libqwayland*.so; do
  if [ -f "$p" ]; then qt_has_wayland=1; break; fi
done
if [ "$qt_has_wayland" = 0 ]; then
  export QT_QPA_PLATFORM=xcb
fi

# From a terminal, detach so the prompt returns. Keep the GUI in-process when
# the user asked for logs, or when not a TTY (menu / autostart).
want_fg=0
[ "${DUNETRAILS_FOREGROUND:-0}" = "1" ] && want_fg=1
for a in "$@"; do
  case "$a" in
    --logfile|--logwindow|--logdir|--debug|-l) want_fg=1 ;;
  esac
done
# Detach by re-running the AppImage itself, NOT by backgrounding AppRun.orig:
# the AppImage runtime unmounts its squashfs as soon as AppRun returns, which
# pulls the Qt plugins, QML and icons out from under the client we just put in
# the background. Re-exec gives the detached client its own runtime and mount.
# The child's stdout is /dev/null, so it is not a TTY and falls through to the
# exec below instead of detaching again.
#
# `trap '' HUP` before forking is load-bearing: setsid only detaches after it
# has been exec'd, and we exit immediately, so closing the terminal can deliver
# SIGHUP to the child while it is still in the old session and kill it. An
# ignored disposition is inherited across fork AND preserved across exec, so
# arming it here covers the whole window (and keeps the client alive when the
# user later closes the terminal, which is the point of detaching).
if [ "$want_fg" = 0 ] && [ -t 1 ] && [ -n "${APPIMAGE:-}" ] && [ -x "$APPIMAGE" ]; then
  trap '' HUP
  if command -v setsid >/dev/null 2>&1; then
    setsid "$APPIMAGE" "$@" </dev/null >/dev/null 2>&1 &
  else
    "$APPIMAGE" "$@" </dev/null >/dev/null 2>&1 &
  fi
  exit 0
fi

exec "$HERE/AppRun.orig" "$@"
APPRUN
} > "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"

# 3. Repack. --appimage-extract-and-run avoids needing FUSE for appimagetool.
TOOL="$(mktemp -d)/appimagetool.AppImage"
if command -v wget >/dev/null 2>&1; then
  wget -qO "${TOOL}" "${APPIMAGETOOL_URL}"
else
  curl -fsSL -o "${TOOL}" "${APPIMAGETOOL_URL}"
fi
chmod +x "${TOOL}"

TMP_OUT="$(mktemp -d)/repacked.AppImage"
ARCH="${ARCH}" "${TOOL}" --appimage-extract-and-run "${APPDIR}" "${TMP_OUT}"
mkdir -p "$(dirname "${OUT}")"
mv -f "${TMP_OUT}" "${OUT}"
chmod +x "${OUT}"
echo "==> embedded self-integration into ${OUT}"
