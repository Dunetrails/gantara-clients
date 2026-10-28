#!/usr/bin/env bash
#
# Register (or remove) a Dunetrails AppImage in the Linux applications menu.
#
# An AppImage is a portable single file: running it never installs a launcher,
# so it won't show up in the applications menu / "programs" list on its own
# (this is normal AppImage behaviour, identical to the official Nextcloud
# AppImages). This script does the desktop integration once, for BOTH our
# clients (Dunetrails sync + Dunetrails Talk), by reusing the `.desktop` entry
# and icon that are already embedded inside the AppImage:
#
#   1. copies the AppImage to a stable location (~/.local/bin),
#   2. extracts the embedded .desktop + icon,
#   3. installs them under ~/.local/share so the menu picks them up,
#      rewriting Exec/Icon to point at the installed copy,
#   4. for the sync client, writes ~/.config/autostart so it starts at login.
#
# It is a per-user install (no root, no sudo). The alternative is to install
# AppImageLauncher, which offers to integrate any AppImage on first launch.
#
# Usage:
#   install-appimage.sh <path-to.AppImage>     # install / update
#   install-appimage.sh --uninstall <name>     # remove (name = app id, e.g. dunetrails-talk)
#   install-appimage.sh --purge <name>         # remove, plus settings/cache/account data
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${APPIMAGE_INSTALL_DIR:-${HOME}/.local/bin}"
APP_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
ICON_ROOT="${XDG_DATA_HOME:-${HOME}/.local/share}/icons/hicolor"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/autostart"

# The sync client's autostart entry is named after APPLICATION_SHORTNAME, because
# that is what Utility::hasLaunchOnStartup()/setLaunchOnStartup() look for. It is
# NOT the .desktop "Name=" (upstream ships "<brand> Desktop"). Getting this wrong
# desynchronises the in-app "Launch on system startup" checkbox from the file that
# actually starts the client.
APPLICATION_SHORTNAME=""
if [ -f "${SCRIPT_DIR}/desktop/branding/branding.env" ]; then
  # shellcheck source=desktop/branding/branding.env
  . "${SCRIPT_DIR}/desktop/branding/branding.env"
fi
AUTOSTART_NAME="${AUTOSTART_NAME:-${APPLICATION_SHORTNAME}}"

die() { echo "error: $*" >&2; exit 1; }

refresh_caches() {
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${APP_DIR}" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -f -t "${ICON_ROOT}" >/dev/null 2>&1 || true
}

uninstall() {
  local id="${1:?usage: install-appimage.sh --uninstall <app-id>}"
  local purge="${2:-no}"

  rm -f "${BIN_DIR}/${id}.AppImage" \
        "${APP_DIR}/${id}.desktop" \
        "${APP_DIR}/.${id}.appimage-path" \
        "${AUTOSTART_DIR}/${id}.desktop"

  # Autostart entries are not named after the app id, and past builds disagreed
  # about the basename, so match on content: anything that launches this app.
  local f
  for f in "${AUTOSTART_DIR}"/*.desktop; do
    [ -e "${f}" ] || continue
    if grep -qE "(^|/)${id}(\.AppImage)?( |\"|$)" "${f}" 2>/dev/null; then
      rm -f "${f}"
    fi
  done
  if [ -n "${AUTOSTART_NAME}" ]; then
    rm -f "${AUTOSTART_DIR}/${AUTOSTART_NAME}.desktop"
  fi

  find "${ICON_ROOT}" -type f -name "${id}.*" -delete 2>/dev/null || true
  refresh_caches
  echo "==> removed ${id} (AppImage, launcher, autostart and icon)"

  if [ "${purge}" = "purge" ]; then
    purge_user_data "${id}"
  fi
}

# Settings, logs, cached avatars and the stored account. Deliberately separate
# from --uninstall: this loses the account and folder configuration.
purge_user_data() {
  local id="$1"
  [ -n "${AUTOSTART_NAME}" ] || die "--purge needs branding.env (or AUTOSTART_NAME=<APPLICATION_SHORTNAME>)"
  local cfg="${XDG_CONFIG_HOME:-${HOME}/.config}/${AUTOSTART_NAME}"
  local data="${XDG_DATA_HOME:-${HOME}/.local/share}/${AUTOSTART_NAME}"
  local cache="${XDG_CACHE_HOME:-${HOME}/.cache}/${AUTOSTART_NAME}"
  rm -rf "${cfg}" "${data}" "${cache}"
  echo "    purged ${cfg}"
  echo "    purged ${data}"
  echo "    purged ${cache}"

  # The client appends its sync folder to the GTK bookmarks (Utility::setupFavLink)
  # and never removes it, so repeated test installs stack up duplicates.
  local bookmarks="${XDG_CONFIG_HOME:-${HOME}/.config}/gtk-3.0/bookmarks"
  if [ -f "${bookmarks}" ] && grep -qi "${AUTOSTART_NAME}" "${bookmarks}"; then
    grep -vi "${AUTOSTART_NAME}" "${bookmarks}" > "${bookmarks}.tmp" || true
    mv -f "${bookmarks}.tmp" "${bookmarks}"
    echo "    cleaned ${bookmarks}"
  fi

  # registerUriHandlerForLocalEditing() writes an xdg-mime default for our
  # .desktop; leaving it behind points "Edit locally" at a file that is gone.
  local mimeapps="${XDG_CONFIG_HOME:-${HOME}/.config}/mimeapps.list"
  if [ -f "${mimeapps}" ] && grep -q "${id}" "${mimeapps}"; then
    grep -v "${id}" "${mimeapps}" > "${mimeapps}.tmp" || true
    mv -f "${mimeapps}.tmp" "${mimeapps}"
    echo "    cleaned ${mimeapps}"
  fi

  echo "==> purged ${id} settings and account data"
  echo "    Note: the synced files themselves were left untouched."
  echo "    Saved passwords stay in the keyring: secret-tool search --all server '<your-host>'"
}

install() {
  local src; src="$(readlink -f "${1}")"
  [ -f "${src}" ] || die "AppImage not found: ${1}"

  chmod +x "${src}" 2>/dev/null || true

  # Unpack the embedded AppDir (no FUSE needed) to read its .desktop + icon.
  local work; work="$(mktemp -d)"
  trap 'rm -rf "${work}"' EXIT
  ( cd "${work}" && "${src}" --appimage-extract >/dev/null ) \
    || die "could not extract ${src} (is it a valid AppImage?)"
  local root="${work}/squashfs-root"
  [ -d "${root}" ] || die "no squashfs-root after extraction"

  local desktop; desktop="$(find "${root}" -maxdepth 1 -name '*.desktop' -print -quit)"
  [ -n "${desktop}" ] || desktop="$(find "${root}/usr/share/applications" -name '*.desktop' -print -quit 2>/dev/null || true)"
  [ -n "${desktop}" ] || die "no .desktop found inside the AppImage"

  # App id = desktop file basename; drives every installed filename.
  local id; id="$(basename "${desktop}" .desktop)"
  local icon_name; icon_name="$(sed -n 's/^Icon=//p' "${desktop}" | head -n1)"
  [ -n "${icon_name}" ] || icon_name="${id}"

  # 1. Stable home for the AppImage itself.
  mkdir -p "${BIN_DIR}"
  local dest="${BIN_DIR}/${id}.AppImage"
  cp -f "${src}" "${dest}"
  chmod +x "${dest}"

  # 2. Icon: pick the largest embedded PNG for this icon name, else any SVG,
  #    else the top-level .DirIcon; install into hicolor under the app id.
  local icon_src size ext
  icon_src="$(find "${root}/usr/share/icons" -type f \( -name "${icon_name}.png" -o -name "${icon_name}.svg" \) 2>/dev/null \
    | sort -t/ -k7 -rn | head -n1)"
  [ -n "${icon_src}" ] || icon_src="$(find "${root}" -maxdepth 1 -type f \( -name "${icon_name}.png" -o -name "${icon_name}.svg" \) -print -quit)"
  [ -n "${icon_src}" ] || { icon_src="$(readlink -f "${root}/.DirIcon" 2>/dev/null || true)"; }
  if [ -n "${icon_src}" ] && [ -f "${icon_src}" ]; then
    ext="${icon_src##*.}"; [ "${ext}" = "svg" ] || ext="png"
    if [ "${ext}" = "svg" ]; then
      size="scalable"
    else
      size="512x512"
    fi
    install -Dm644 "${icon_src}" "${ICON_ROOT}/${size}/apps/${id}.${ext}"
    # Qt autostart uses Icon=<APPLICATION_ICON_NAME> (Dunetrails), not the reverse-DNS id.
    if [ "${icon_name}" != "${id}" ]; then
      install -Dm644 "${icon_src}" "${ICON_ROOT}/${size}/apps/${icon_name}.${ext}"
    fi
  else
    echo "warning: no icon found inside the AppImage; menu entry will be iconless" >&2
  fi

  # 3. Launcher: build a clean, single-group [Desktop Entry] with a guaranteed
  #    Exec pointing at the installed AppImage. Do NOT reuse the embedded Exec
  #    argv — Electron binaries are often named "Dunetrails Talk" (space), and
  #    stripping only the first token leaves a stray "Talk" argument that makes
  #    menu/dock launches fail silently. Always invoke the AppImage + %U.
  mkdir -p "${APP_DIR}"
  local out="${APP_DIR}/${id}.desktop"
  local name comment categories mimetype wmclass exec_path
  name="$(sed -n 's/^Name=//p'          "${desktop}" | head -n1)"; [ -n "${name}" ] || name="${id}"
  comment="$(sed -n 's/^Comment=//p'    "${desktop}" | head -n1)"
  categories="$(sed -n 's/^Categories=//p' "${desktop}" | head -n1)"; [ -n "${categories}" ] || categories="Utility;"
  # Keep MimeType: the client registers itself as the handler for the server's
  # "Edit locally" links, and xdg-open only resolves that if we declare the type.
  mimetype="$(sed -n 's/^MimeType=//p' "${desktop}" | head -n1)"
  wmclass="$(sed -n 's/^StartupWMClass=//p' "${desktop}" | head -n1)"
  # Sync client's upstream .desktop omits StartupWMClass; use the binary name (Qt WM_CLASS).
  [ -n "${wmclass}" ] || wmclass="$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "${desktop}" | head -n1 | tr -d '\"')"
  [ -n "${wmclass}" ] || wmclass="${name}"
  # Quote only when the path has spaces (avoid ' inside [...] — breaks bash parsing).
  case "${dest}" in
    *" "*) exec_path="\"${dest}\"" ;;
    *)     exec_path="${dest}" ;;
  esac
  {
    echo "[Desktop Entry]"
    echo "Type=Application"
    echo "Version=1.0"
    echo "Name=${name}"
    if [ -n "${comment}" ]; then echo "Comment=${comment}"; fi
    echo "Exec=${exec_path} %U"
    echo "TryExec=${dest}"
    echo "Icon=${id}"
    echo "Terminal=false"
    echo "Categories=${categories}"
    if [ -n "${mimetype}" ]; then echo "MimeType=${mimetype}"; fi
    echo "StartupWMClass=${wmclass}"
    echo "SingleMainWindow=true"
  } > "${out}"
  chmod +x "${out}"

  # Sync client: XDG autostart at login, under the basename Qt itself uses
  # (APPLICATION_SHORTNAME — see the note at the top of this file). Talk is
  # Electron and is not registered here. Exec must be the AppImage, not the FUSE
  # mount path the Qt client sometimes writes (/tmp/.mount_*).
  local autostart=""
  case "${id}" in
    *[Tt]alk*) ;;
    *)
      local aname="${AUTOSTART_NAME}"
      [ -n "${aname}" ] || aname="${icon_name}"
      mkdir -p "${AUTOSTART_DIR}"
      autostart="${AUTOSTART_DIR}/${aname}.desktop"
      # Drop entries older versions of this script wrote under the Name= basename.
      if [ "${name}" != "${aname}" ]; then rm -f "${AUTOSTART_DIR}/${name}.desktop"; fi
      {
        echo "[Desktop Entry]"
        echo "Name=${name}"
        echo "GenericName=File Synchronizer"
        echo "Exec=${exec_path} --background"
        echo "Terminal=false"
        echo "Icon=${icon_name}"
        echo "Categories=Network"
        echo "Type=Application"
        echo "StartupNotify=false"
        echo "X-GNOME-Autostart-enabled=true"
        echo "X-GNOME-Autostart-Delay=10"
      } > "${autostart}"
      chmod +x "${autostart}"
      ;;
  esac

  refresh_caches
  echo "==> installed ${id}"
  echo "    binary : ${dest}"
  echo "    menu   : ${out}"
  if [ -n "${autostart}" ]; then
    echo "    autostart: ${autostart}"
  fi
  echo "You may need to log out/in (or wait a moment) for it to appear in the menu."
}

case "${1:-}" in
  ""|-h|--help) sed -n '2,25p' "$0"; exit 0 ;;
  --uninstall)  uninstall "${2:-}" ;;
  --purge)      uninstall "${2:-}" purge ;;
  *)            install "${1}" ;;
esac
