#!/bin/sh
# Build-time patches to baked appstore apps (runs after install-apps.sh).
#
# integration_google: request the narrowest Google OAuth scopes, as required by Google's OAuth
# verification (least privilege; the consent screen must show exactly the scopes declared in the
# Cloud Console Data Access page):
#   - calendar.readonly -> calendar.calendarlist.readonly. The import only calls calendarList.list,
#     colors.get and events.list; per the Calendar API discovery document the first two accept
#     calendar.calendarlist.readonly and events.list accepts calendar.events.readonly (already
#     requested). calendar.readonly also subsumed calendar.events.readonly on the consent screen.
#   - contacts.other.readonly dropped: the optional "Include other contacts" toggle is hidden when
#     the scope is not granted, and the otherContacts calls only run behind that toggle.
# Patched files no longer match the app's signature, so appinfo/signature.json is removed; for
# non-shipped apps Nextcloud only runs the integrity check when that file exists.
# Each patch must apply exactly once, so an upstream change fails the build instead of silently
# shipping the old scopes. Re-check the patterns whenever integration_google is bumped.
set -eu

CUSTOM_APPS=/usr/src/nextcloud/custom_apps
G="${CUSTOM_APPS}/integration_google"

[ -d "${G}" ] || { echo "patch-apps: integration_google not baked, nothing to do"; exit 0; }

replace_once() {
  file="$1"; from="$2"; to="$3"
  n="$(grep -oF -- "${from}" "${file}" | wc -l)"
  [ "${n}" -eq 1 ] || { echo "patch-apps: ERROR expected 1 match of '${from}' in ${file}, found ${n}"; exit 1; }
  FROM="${from}" TO="${to}" perl -0pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/' "${file}"
}

JS="${G}/js/integration_google-personalSettings.mjs"
PHP="${G}/lib/Controller/ConfigController.php"
AUTH="https://www.googleapis.com/auth"

replace_once "${JS}" "\"${AUTH}/calendar.readonly\"" "\"${AUTH}/calendar.calendarlist.readonly\""
replace_once "${JS}" ",\"${AUTH}/contacts.other.readonly\"" ""
replace_once "${PHP}" "'${AUTH}/calendar.readonly'" "'${AUTH}/calendar.calendarlist.readonly'"
rm -f "${G}/appinfo/signature.json"

echo "patch-apps: integration_google scopes requested:"
grep -oE "${AUTH}/[a-z.]+|\"openid\"|\"profile\"" "${JS}" | sort -u
echo "patch-apps: done"
