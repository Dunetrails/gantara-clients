#!/usr/bin/env bash
# Inspect a Talk AppImage: Electron version, AppRun env, tray PNG, webpack tray code.
set -euo pipefail
SRC="${1:?usage: inspect-appimage.sh <AppImage>}"
SRC="$(readlink -f "${SRC}")"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
cp -f "${SRC}" "${WORKDIR}/talk.AppImage"
chmod +x "${WORKDIR}/talk.AppImage"
cd "${WORKDIR}"
if ! ./talk.AppImage --appimage-extract >/dev/null 2>&1; then
  OFFSET="$(LC_ALL=C grep -aob 'hsqs' talk.AppImage | head -1 | cut -d: -f1)"
  unsquashfs -o "${OFFSET}" -d squashfs-root talk.AppImage >/dev/null
fi
ROOT="${WORKDIR}/squashfs-root"
fail=0
note() { printf '%s\n' "$*"; }
ok() { printf 'OK   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

note "== Electron version"
if [ -f "${ROOT}/version" ]; then
  ver="$(tr -d '\r\n' < "${ROOT}/version")"
  note "    ${ver}"
  # electron#52674: 43.3-43.4 and 44.0 broke StatusNotifier on GNOME/Cinnamon/Xfce;
  # fixed in 43.5.0 and 44.1.0.
  case "${ver}" in
    43.[34].*|44.0.*) bad "Electron ${ver} has the StatusNotifier multiplexer bug (electron#52674; need 43.5+ or 44.1+)" ;;
    43.*|4[4-9].*|[5-9][0-9].*) ok "Electron ${ver} is outside the electron#52674 range" ;;
    *) note "    (unrecognized Electron ${ver})" ;;
  esac
else
  bad "no version file at AppDir root"
fi

note "== AppRun (outer wrapper)"
if grep -q 'ELECTRON_OZONE_PLATFORM_HINT=.*x11' "${ROOT}/AppRun" || grep -q 'ozone-platform=x11' "${ROOT}/AppRun"; then
  bad "outer AppRun forces X11 (ungroups the GNOME dock icon from dunetrails-talk)"
else
  ok "outer AppRun does not force X11"
fi
if grep -q 'TMPDIR=/tmp' "${ROOT}/AppRun" || grep -q 'export TMPDIR=/tmp' "${ROOT}/AppRun"; then
  ok "outer AppRun pins TMPDIR=/tmp"
else
  bad "outer AppRun does not pin TMPDIR=/tmp"
fi

note "== AppRun.orig (inner Electron launcher)"
if [ -f "${ROOT}/AppRun.orig" ]; then
  if grep -q 'ozone-platform=x11' "${ROOT}/AppRun.orig" || grep -q 'ELECTRON_OZONE_PLATFORM_HINT=.*x11' "${ROOT}/AppRun.orig"; then
    bad "inner AppRun forces X11 (ungroups the GNOME dock icon)"
  else
    ok "inner AppRun does not force X11"
  fi
  if grep -q -- '--class=dunetrails-talk' "${ROOT}/AppRun.orig"; then
    ok "inner AppRun sets --class=dunetrails-talk"
  else
    bad "inner AppRun missing --class=dunetrails-talk"
  fi
  if grep -q 'TMPDIR=/tmp' "${ROOT}/AppRun.orig"; then
    ok "inner AppRun pins TMPDIR=/tmp"
  else
    bad "inner AppRun does not pin TMPDIR=/tmp"
  fi
else
  bad "no AppRun.orig"
fi

note "== sni_tray.py (GNOME-compatible StatusNotifier helper)"
SNI=""
if [ -f "${ROOT}/sni_tray.py" ]; then
  SNI="${ROOT}/sni_tray.py"
elif [ -f "${ROOT}/resources/sni_tray.py" ]; then
  SNI="${ROOT}/resources/sni_tray.py"
fi
if [ -n "${SNI}" ]; then
  ok "sni_tray.py is in the AppImage"
  if grep -q 'gi.repository import Gio' "${SNI}"; then
    ok "sni_tray.py uses Gio (GNOME AppIndicator can parse properties)"
  else
    bad "sni_tray.py does not use Gio (hand-rolled D-Bus is dropped by AppIndicator)"
  fi
else
  bad "sni_tray.py missing from AppImage (GNOME tray will not work)"
fi

note "== Tray PNG in asar"
ASAR="$(find "${ROOT}" -name 'app.asar' | head -1)"
if [ -z "${ASAR}" ]; then
  bad "no app.asar"
else
  if command -v npx >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
    python3 - "${ASAR}" <<'PY' || true
import sys, struct, os
path = sys.argv[1]
with open(path, 'rb') as f:
    raw = f.read()
# Electron asar: JSON pickle header. Use a string search for the tray file.
for name in (b'IconTrayLinux.png', b'icon.png', b'setupTray', b'linux-sni-tray'):
    print(('OK  ' if name in raw else 'MISS') + '  asar contains ' + name.decode())
PY
  fi
fi

exit "${fail}"
