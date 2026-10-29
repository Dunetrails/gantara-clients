#!/usr/bin/env bash
#
# Remove every trace of the Dunetrails Linux clients from the current user
# account, so the next AppImage starts from a clean slate.
#
# Why this exists: testing several builds in a row leaves state behind that the
# AppImage cannot clean up itself, and some of it actively breaks the next run.
#
#   * Launchers and autostart entries keep pointing at AppImages that were moved
#     or deleted, and older builds wrote the autostart entry under a different
#     basename than the client reads, so the client can keep starting at login
#     after you switch the setting off.
#   * The settings directory is shared across versions. Running an older client
#     after a newer one triggers the "settings were configured in newer versions
#     of this client" dialog and backs the config up on every start.
#   * The client appends its sync folder to the GTK bookmarks on every setup and
#     never removes it, so the file-manager sidebar collects duplicates.
#
# SAFETY: this never touches synced files. Only per-user application state under
# ~/.config, ~/.cache and ~/.local is removed, and nothing is deleted unless you
# pass --yes.
#
# Usage:
#   reset-linux-clients.sh              # dry run: list what would be removed
#   reset-linux-clients.sh --yes        # actually remove it
#   reset-linux-clients.sh --yes --keep-accounts   # keep settings/accounts,
#                                                  # only fix menu + autostart
#
set -euo pipefail

APPLY=0
KEEP_ACCOUNTS=0
for arg in "$@"; do
  case "${arg}" in
    --yes|-y)        APPLY=1 ;;
    --keep-accounts) KEEP_ACCOUNTS=1 ;;
    -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "error: unknown option: ${arg}" >&2; exit 1 ;;
  esac
done

CONFIG_HOME="${XDG_CONFIG_HOME:-${HOME}/.config}"
DATA_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}"
CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"
AUTOSTART_DIR="${CONFIG_HOME}/autostart"
APP_DIR="${DATA_HOME}/applications"
ICON_ROOT="${DATA_HOME}/icons/hicolor"

# Case-insensitive match for anything of ours: "dunetrails", "Dunetrails Talk",
# the reverse-DNS ids, and the AppImage filenames. The clients are shown as
# Gantara, but every id, executable and installed filename still says dunetrails.
BRAND_RE='dunetrails'

found=0
note() { printf '  %s\n' "$*"; }
header() { printf '\n== %s\n' "$*"; }

remove_path() {
  local p="$1"
  [ -e "${p}" ] || return 0
  found=1
  if [ "${APPLY}" = 1 ]; then
    rm -rf "${p}"
    note "removed  ${p}"
  else
    note "would remove  ${p}"
  fi
}

strip_lines() { # $1=file  $2=grep -E pattern
  local file="$1" pattern="$2"
  [ -f "${file}" ] || return 0
  grep -qiE "${pattern}" "${file}" || return 0
  found=1
  if [ "${APPLY}" = 1 ]; then
    grep -viE "${pattern}" "${file}" > "${file}.dtnew" || true
    mv -f "${file}.dtnew" "${file}"
    note "cleaned  ${file}"
  else
    note "would clean  ${file}"
    grep -inE "${pattern}" "${file}" | sed 's/^/      /'
  fi
}

# Collect client PIDs. Never use a bare `pkill -f dunetrails`: this script is
# itself usually run from a path containing the brand name, so it would match
# its own command line (and the shell that launched it) and commit suicide.
client_pids() {
  local pid cmd
  for pid in $(pgrep -fi "${BRAND_RE}" 2>/dev/null || true); do
    [ "${pid}" = "$$" ] && continue
    [ "${pid}" = "${PPID}" ] && continue
    cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
    [ -n "${cmd}" ] || continue
    case "${cmd}" in
      *reset-linux-clients*|*install-appimage*|*pgrep*) continue ;;
    esac
    printf '%s\t%s\n' "${pid}" "${cmd}"
  done
}

header "Running clients"
pids="$(client_pids)"
if [ -n "${pids}" ]; then
  found=1
  printf '%s\n' "${pids}" | sed 's/^/  /'
  if [ "${APPLY}" = 1 ]; then
    printf '%s\n' "${pids}" | cut -f1 | xargs -r kill 2>/dev/null || true
    sleep 2
    printf '%s\n' "${pids}" | cut -f1 | xargs -r kill -9 2>/dev/null || true
    note "stopped"
  else
    note "would stop these"
  fi
else
  note "none running"
fi

header "Application menu entries"
# find, not a glob: the AppRun's ".<app-id>.appimage-path" integration stamp is
# a dotfile and would otherwise be left behind.
if [ -d "${APP_DIR}" ]; then
  while IFS= read -r f; do
    remove_path "${f}"
  done < <(find "${APP_DIR}" -maxdepth 1 -iname "*dunetrails*" 2>/dev/null | sort)
fi

header "Autostart entries"
# Match on content, not filename: builds have used the app id, the .desktop
# "Name=" ("Dunetrails Desktop") and APPLICATION_SHORTNAME ("Dunetrails").
for f in "${AUTOSTART_DIR}"/*.desktop; do
  [ -e "${f}" ] || continue
  if grep -qiE "${BRAND_RE}" "${f}" 2>/dev/null; then
    remove_path "${f}"
  fi
done

header "Installed AppImages"
for f in "${HOME}/.local/bin"/*.AppImage; do
  [ -e "${f}" ] || continue
  case "$(basename "${f}")" in
    *[Dd]unetrails*|Gantara_*) remove_path "${f}" ;;
  esac
done

header "Icons"
if [ -d "${ICON_ROOT}" ]; then
  while IFS= read -r f; do
    remove_path "${f}"
  done < <(find "${ICON_ROOT}" -type f -iname "*dunetrails*" 2>/dev/null)
fi

header "Settings, accounts, logs and cache"
if [ "${KEEP_ACCOUNTS}" = 1 ]; then
  note "skipped (--keep-accounts)"
else
  for d in "${CONFIG_HOME}" "${DATA_HOME}" "${CACHE_HOME}"; do
    for p in "${d}"/*; do
      [ -e "${p}" ] || continue
      case "$(basename "${p}")" in
        [Dd]unetrails*) remove_path "${p}" ;;
      esac
    done
  done
fi

header "File-manager bookmarks and MIME defaults"
strip_lines "${CONFIG_HOME}/gtk-3.0/bookmarks" "${BRAND_RE}"
strip_lines "${CONFIG_HOME}/gtk-4.0/bookmarks" "${BRAND_RE}"
strip_lines "${CONFIG_HOME}/mimeapps.list" "${BRAND_RE}"
strip_lines "${DATA_HOME}/applications/mimeapps.list" "${BRAND_RE}"

header "Result"
if [ "${found}" = 0 ]; then
  echo "  Nothing left to clean."
  exit 0
fi

if [ "${APPLY}" = 1 ]; then
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "${APP_DIR}" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache   >/dev/null 2>&1 && gtk-update-icon-cache -f -t "${ICON_ROOT}" >/dev/null 2>&1 || true
  echo "  Done. Log out and back in so the session forgets the old autostart entry."
  echo
  echo "  Left untouched on purpose:"
  echo "    - your synced files (e.g. ~/Dunetrails). Delete the folder yourself if"
  echo "      you want the next sign-in to re-download everything."
  echo "    - the saved password in the keyring. To drop it:"
  echo "        secret-tool search --all server '<your-server-host>'"
  echo "        secret-tool clear server '<your-server-host>'"
else
  echo "  Dry run — nothing was changed. Re-run with --yes to apply."
fi
