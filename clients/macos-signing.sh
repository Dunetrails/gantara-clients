#!/usr/bin/env bash
#
# Developer ID signing and notarisation of the macOS clients. See SIGNING.md in
# public/gantara-clients for how users verify, and docs/runbooks/macos-code-signing.md for
# the Apple side.
#
#   macos-signing.sh import
#       Creates a throwaway keychain, imports the Developer ID identities from
#       MACOS_CERTIFICATES_P12 and, when set, MACOS_INSTALLER_P12 (each base64 of a .p12; Apple
#       wants a separate key per certificate, and a .p12 holds one key) with
#       MACOS_CERTIFICATES_PASSWORD, puts it on the search list so codesign, productsign and
#       @electron/osx-sign find it, and exports MACOS_KEYCHAIN, MACOS_SIGN_IDENTITY
#       ("Developer ID Application: … (<team>)") and, when there is one,
#       MACOS_INSTALLER_IDENTITY ("Developer ID Installer: …") to later steps. Both must belong
#       to APPLE_TEAM_ID.
#   macos-signing.sh sign <file>...
#       codesign with the Developer ID Application identity and a secure timestamp (for DMGs;
#       app bundles are signed by the build tools themselves).
#   macos-signing.sh notarize <file>...
#       Submits each .dmg / .pkg / .zip to Apple's notary service (APPLE_ID, APPLE_ID_PASSWORD,
#       APPLE_TEAM_ID), waits, prints Apple's log when it is rejected, and staples the ticket
#       to .dmg and .pkg files.
#   macos-signing.sh verify <file>...
#       .app: deep strict signature check, hardened runtime, team, Gatekeeper and the stapled
#       ticket. .dmg: the image's own signature and ticket, then every .app inside it. .pkg:
#       installer signature, Gatekeeper and ticket, then every .app in its payload (without
#       the stapler check: only the package carries the ticket, so Gatekeeper's online check
#       is what proves those were notarised). Fails on the first problem.
#   macos-signing.sh cleanup
#       Deletes the keychain again.
#
# Only the .p12 password and the Apple ID app-specific password are secret; both arrive as
# environment variables and are never written to disk or the log.
set -euo pipefail

DEVELOPER_ID_CA_URL="https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer"
DEVELOPER_ID_CA_SHA256="f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"

P12_FILE=""
trap 'rm -f "${P12_FILE}"' EXIT

die() { echo "::error::$*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "$1 is not set"; }

export_env() {
  export "$1=$2"
  if [ -n "${GITHUB_ENV:-}" ]; then printf '%s=%s\n' "$1" "$2" >>"${GITHUB_ENV}"; fi
}

# import_p12 <variable> <keychain> <tmp>: imports the base64 .p12 held in that variable.
import_p12() {
  P12_FILE="$(mktemp "$3/certs.XXXXXX")"
  printf '%s' "${!1}" | base64 --decode >"${P12_FILE}" || die "$1 is not valid base64"
  security import "${P12_FILE}" -k "$2" -f pkcs12 -P "${MACOS_CERTIFICATES_PASSWORD}" \
    -T /usr/bin/codesign -T /usr/bin/productsign -T /usr/bin/security >/dev/null ||
    die "could not import $1 (wrong MACOS_CERTIFICATES_PASSWORD?)"
  rm -f "${P12_FILE}"
}

do_import() {
  need MACOS_CERTIFICATES_P12
  need MACOS_CERTIFICATES_PASSWORD
  need APPLE_TEAM_ID
  local tmp keychain kc_pass identities app installer
  tmp="${RUNNER_TEMP:-$(mktemp -d)}"
  keychain="${tmp}/gantara-signing.keychain-db"
  kc_pass="$(openssl rand -hex 24)"

  security delete-keychain "${keychain}" >/dev/null 2>&1 || true
  security create-keychain -p "${kc_pass}" "${keychain}"
  security set-keychain-settings -lut 21600 "${keychain}"
  security unlock-keychain -p "${kc_pass}" "${keychain}"
  # The intermediate that issues current Developer ID certificates. Runner images do not
  # always carry it, and without it the identity does not count as valid.
  curl -fsSL --retry 3 -o "${tmp}/DeveloperIDG2CA.cer" "${DEVELOPER_ID_CA_URL}"
  [ "$(shasum -a 256 "${tmp}/DeveloperIDG2CA.cer" | cut -d' ' -f1)" = "${DEVELOPER_ID_CA_SHA256}" ] ||
    die "${DEVELOPER_ID_CA_URL} does not have the expected SHA-256"
  security import "${tmp}/DeveloperIDG2CA.cer" -k "${keychain}" >/dev/null
  import_p12 MACOS_CERTIFICATES_P12 "${keychain}" "${tmp}"
  if [ -n "${MACOS_INSTALLER_P12:-}" ]; then
    import_p12 MACOS_INSTALLER_P12 "${keychain}" "${tmp}"
  fi
  # Lets codesign use the keys without the "allow access" dialog nobody can click on a runner.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${kc_pass}" "${keychain}" >/dev/null
  # shellcheck disable=SC2046 # the existing search list is a list of quoted paths
  security list-keychains -d user -s "${keychain}" $(security list-keychains -d user | tr -d '"')

  identities="$(security find-identity -v "${keychain}")"
  app="$(printf '%s\n' "${identities}" | sed -n "s/.*\"\(Developer ID Application: .* (${APPLE_TEAM_ID})\)\".*/\1/p" | head -n1)"
  installer="$(printf '%s\n' "${identities}" | sed -n "s/.*\"\(Developer ID Installer: .* (${APPLE_TEAM_ID})\)\".*/\1/p" | head -n1)"
  if [ -z "${app}" ]; then
    printf '%s\n' "${identities}" | sed 's/^/    /' >&2
    die "MACOS_CERTIFICATES_P12 holds no valid \"Developer ID Application: … (${APPLE_TEAM_ID})\" identity"
  fi
  export_env MACOS_KEYCHAIN "${keychain}"
  export_env MACOS_SIGN_IDENTITY "${app}"
  echo "signing identity:   ${app}"
  if [ -n "${installer}" ]; then
    export_env MACOS_INSTALLER_IDENTITY "${installer}"
    echo "installer identity: ${installer}"
  else
    [ -z "${MACOS_INSTALLER_P12:-}" ] ||
      die "MACOS_INSTALLER_P12 holds no valid \"Developer ID Installer: … (${APPLE_TEAM_ID})\" identity"
    echo "installer identity: none (MACOS_INSTALLER_P12 is only needed for .pkg installers)"
  fi
}

do_sign() {
  need MACOS_SIGN_IDENTITY
  [ "$#" -gt 0 ] || die "sign: no files given"
  for f in "$@"; do
    codesign --force --timestamp --sign "${MACOS_SIGN_IDENTITY}" "${f}"
    codesign --verify --strict --verbose=2 "${f}"
  done
}

do_notarize() {
  need APPLE_ID
  need APPLE_ID_PASSWORD
  need APPLE_TEAM_ID
  [ "$#" -gt 0 ] || die "notarize: no files given"
  local f out id status
  for f in "$@"; do
    echo "notarising ${f} (usually a few minutes)"
    out="$(xcrun notarytool submit "${f}" --apple-id "${APPLE_ID}" --password "${APPLE_ID_PASSWORD}" \
      --team-id "${APPLE_TEAM_ID}" --wait --timeout 1h --output-format json)" ||
      die "notarytool submit failed for ${f}: ${out}"
    id="$(printf '%s' "${out}" | jq -r '.id // empty')"
    status="$(printf '%s' "${out}" | jq -r '.status // empty')"
    echo "submission ${id}: ${status}"
    if [ "${status}" != "Accepted" ]; then
      [ -z "${id}" ] || xcrun notarytool log "${id}" --apple-id "${APPLE_ID}" --password "${APPLE_ID_PASSWORD}" \
        --team-id "${APPLE_TEAM_ID}" || true
      die "Apple did not accept ${f} (${status:-no status}); its log is above"
    fi
    case "${f}" in
      *.dmg | *.pkg) xcrun stapler staple "${f}" ;;
    esac
  done
}

# verify_app <app> [unstapled]
verify_app() {
  local app="$1" details
  codesign --verify --deep --strict --verbose=2 "${app}"
  details="$(codesign --display --verbose=2 "${app}" 2>&1)"
  printf '%s\n' "${details}" | grep -q "^TeamIdentifier=${APPLE_TEAM_ID}$" ||
    die "${app} is not signed by team ${APPLE_TEAM_ID}"
  printf '%s\n' "${details}" | grep -q '^Authority=Developer ID Application: ' ||
    die "${app} is not signed with a Developer ID Application certificate"
  printf '%s\n' "${details}" | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' ||
    die "${app} is not signed with the hardened runtime (notarisation requires it)"
  spctl --assess --type execute --verbose=4 "${app}"
  [ "${2:-}" = unstapled ] || xcrun stapler validate "${app}"
  echo "verified ${app}: $(printf '%s\n' "${details}" | grep -m1 '^Authority=')"
}

do_verify() {
  need APPLE_TEAM_ID
  [ "$#" -gt 0 ] || die "verify: no files given"
  local f mnt apps details
  for f in "$@"; do
    [ -e "${f}" ] || die "not found: ${f}"
    case "${f}" in
      *.app) verify_app "${f}" ;;
      *.dmg)
        codesign --verify --strict --verbose=2 "${f}"
        codesign --display --verbose=2 "${f}" 2>&1 | grep -q "^TeamIdentifier=${APPLE_TEAM_ID}$" ||
          die "${f} is not signed by team ${APPLE_TEAM_ID}"
        spctl --assess --type open --context context:primary-signature --verbose=4 "${f}"
        xcrun stapler validate "${f}"
        mnt="$(mktemp -d)"
        hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "${mnt}" "${f}" >/dev/null
        apps="$(find "${mnt}" -maxdepth 1 -name '*.app' -type d)"
        if [ -z "${apps}" ]; then
          hdiutil detach "${mnt}" >/dev/null
          die "${f} contains no .app"
        fi
        while IFS= read -r a; do verify_app "${a}"; done <<<"${apps}"
        hdiutil detach "${mnt}" >/dev/null
        ;;
      *.pkg)
        details="$(pkgutil --check-signature "${f}")"
        printf '%s\n' "${details}"
        printf '%s\n' "${details}" | grep -q "Developer ID Installer: .*(${APPLE_TEAM_ID})" ||
          die "${f} is not signed with a Developer ID Installer certificate of team ${APPLE_TEAM_ID}"
        spctl --assess --type install --verbose=4 "${f}"
        xcrun stapler validate "${f}"
        mnt="$(mktemp -d)"
        pkgutil --expand-full "${f}" "${mnt}/expanded" >/dev/null
        apps="$(find "${mnt}/expanded" -type d -name '*.app' -prune)"
        if [ -z "${apps}" ]; then
          rm -rf "${mnt}"
          die "${f} contains no .app"
        fi
        while IFS= read -r a; do verify_app "${a}" unstapled; done <<<"${apps}"
        rm -rf "${mnt}"
        ;;
      *) die "verify: do not know how to check ${f}" ;;
    esac
  done
}

do_cleanup() {
  local keychain="${MACOS_KEYCHAIN:-${RUNNER_TEMP:-/nonexistent}/gantara-signing.keychain-db}"
  if [ -f "${keychain}" ]; then
    security delete-keychain "${keychain}"
    echo "deleted ${keychain}"
  fi
}

action="${1:-}"
shift || true
case "${action}" in
  import) do_import ;;
  sign) do_sign "$@" ;;
  notarize) do_notarize "$@" ;;
  verify) do_verify "$@" ;;
  cleanup) do_cleanup ;;
  *) die "usage: macos-signing.sh import | sign <file>... | notarize <file>... | verify <file>... | cleanup" ;;
esac
