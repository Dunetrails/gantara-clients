#!/usr/bin/env bash
#
# Compliance sweep over a talk-desktop tree that apply-branding.sh has already
# rewritten. Fails when a user-visible Nextcloud mark or update endpoint survived.
#
# Usage: verify-branding.sh <path-to-talk-desktop-checkout>
#
set -euo pipefail

SRC="${1:?usage: verify-branding.sh <talk-desktop-src-dir>}"
SRC="$(cd -- "${SRC}" && pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

failures=0
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }
pass() { printf 'ok    %s\n' "$*"; }

expect_in_file() {
  local file="$1" needle="$2" what="$3"
  if [ -f "${SRC}/${file}" ] && grep -qF -- "${needle}" "${SRC}/${file}"; then
    pass "${what}"
  else
    fail "${what} — expected \"${needle}\" in ${file}"
  fi
}

forbid_in_file() {
  local file="$1" needle="$2" what="$3"
  if [ ! -f "${SRC}/${file}" ]; then
    fail "${what} — ${file} missing"
    return
  fi
  if grep -qF -- "${needle}" "${SRC}/${file}"; then
    fail "${what} — found \"${needle}\" in ${file}"
  else
    pass "${what}"
  fi
}

cd "${SRC}"

echo "==> Verifying Gantara Talk branding in ${SRC}"

# Branding overlay landed
if [ -f .overrides/build.config.json ]; then
  pass "branded build.config staged"
else
  fail "missing .overrides/build.config.json"
fi
expect_in_file .overrides/build.config.json '"applicationName": "Dunetrails Talk"' \
  "install identity is still Dunetrails Talk (settings dir, Squirrel id)"
expect_in_file .overrides/build.config.json '"displayName": "Gantara Talk"' \
  "display name is Gantara Talk"
expect_in_file webpack.main.config.js 'applicationName: displayName || c.applicationName' \
  "main process shows the display name"
expect_in_file webpack.renderer.config.js 'applicationName: displayName || c.applicationName' \
  "renderer shows the display name"
expect_in_file forge.config.js 'ProductName: BUILD_CONFIG.displayName' \
  "Windows exe metadata / shortcuts use the display name"
expect_in_file forge.config.js 'title: BUILD_CONFIG.displayName' \
  "Add/Remove Programs entry uses the display name"
expect_in_file .overrides/build.config.json '"helpUrl": "https://gantara.eu/support"' \
  "help URL is gantara.eu"
expect_in_file .overrides/build.config.json '"privacyUrl": "https://gantara.eu/privacy-policy"' \
  "privacy URL is gantara.eu"
expect_in_file .overrides/build.config.json '"windowsExe": true' \
  "Windows Squirrel EXE enabled"
expect_in_file .overrides/build.config.json '"windowsMsi": false' \
  "Windows MSI left off (no WiX / no signing path)"

# Names, IDs, installer metadata
expect_in_file package.json '"productName": "Dunetrails Talk"' \
  "package.json productName rewritten"
forbid_in_file package.json '"productName": "Nextcloud Talk"' \
  "package.json no longer ships Nextcloud Talk as productName"
expect_in_file package.json '"desktopName": "dunetrails-talk"' \
  "Linux desktop id is dunetrails-talk (not com.nextcloud.*)"

# Auto-update: branded builds must not poll nextcloud-releases or GitHub.
expect_in_file src/app/githubRelease.service.ts 'if (BUILD_CONFIG.isBranded)' \
  "checkForUpdate short-circuits on branded builds"
expect_in_file src/main.js '!BUILD_CONFIG.isBranded' \
  "release-notification scheduler stays off for branded builds"
forbid_in_file src/authentication/renderer/AuthenticationApp.vue 'try.nextcloud.com' \
  "login placeholder is not try.nextcloud.com"
expect_in_file src/authentication/renderer/AuthenticationApp.vue '<<tenant>>.gantara.eu' \
  "login placeholder is the Gantara tenant pattern"

# Restart behaviour (Linux tray users otherwise never restart)
expect_in_file src/app/system.utils.ts 'execPath: process.env.APPIMAGE' \
  "relaunch re-executes the AppImage, not its vanished FUSE mount"
expect_in_file src/talk/renderer/TalkWrapper/TalkWrapper.vue 'relaunchOnceHidden()' \
  "'server was updated' restarts in the background once hidden"

# Windows Squirrel: Nextcloud GitHub icon URL and loading GIF must be gone.
forbid_in_file forge.config.js 'raw.githubusercontent.com/nextcloud/talk-desktop' \
  "Squirrel iconUrl is not the Nextcloud GitHub .ico"
expect_in_file forge.config.js 'https://gantara.eu/talk-desktop/icon.ico' \
  "Squirrel iconUrl points at gantara.eu"
expect_in_file forge.config.js 'signWithParams: hasWindowsSign && process.env.WINDOWS_SIGN_PARAMS' \
  "Authenticode still gated on WINDOWS_SIGN_PARAMS (unset = unsigned)"

if [ -f img/squirrel-install-loading.gif ] && [ -f "${SCRIPT_DIR}/assets/squirrel-install-loading.gif" ]; then
  if cmp -s img/squirrel-install-loading.gif "${SCRIPT_DIR}/assets/squirrel-install-loading.gif"; then
    pass "Squirrel loading GIF is the Gantara overlay"
  else
    fail "img/squirrel-install-loading.gif does not match branding/assets overlay"
  fi
else
  fail "Squirrel loading GIF missing (installer would show Nextcloud art)"
fi

# Logos users actually see, and the icon-gen sources
for svg in talk-logo.svg server-logo-plain.svg talk-icon-plain-dark.svg talk-icon-rounded.svg talk-icon-rounded-spaced.svg; do
  if [ -f "img/${svg}" ] && grep -q 'data-brand="gantara"' "img/${svg}"; then
    pass "img/${svg} is the Gantara logo"
  else
    fail "img/${svg} was not replaced with the Gantara logo"
  fi
done

# About dialog must not send branded users to github.com/nextcloud
expect_in_file src/help/renderer/HelpApp.vue 'v-if="!BUILD_CONFIG.isBranded"' \
  "About dialog hides Nextcloud GitHub Issues/Source links when branded"

if [ "${failures}" -ne 0 ]; then
  echo "==> ${failures} branding check(s) failed"
  exit 1
fi
echo "==> Branding verification passed"
