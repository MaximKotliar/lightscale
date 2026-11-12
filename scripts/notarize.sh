#!/bin/bash
# Notarizes an app signed with a Developer ID (SIGN_IDENTITY in scripts/build-app.sh) and staples the ticket, so
# Gatekeeper opens it without asking, even offline.
#   scripts/notarize.sh build/Lightscale.app
# Credentials, either:
#   NOTARY_PROFILE=name       saved once with `xcrun notarytool store-credentials name` (a Mac)
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD    an app-specific password (CI)
set -euo pipefail
APP=${1:?usage: notarize.sh PATH.app}
if [ -n "${NOTARY_PROFILE:-}" ]; then
    AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
    : "${APPLE_ID:?set NOTARY_PROFILE, or APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"
    AUTH=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
fi
codesign --verify --deep --strict "$APP"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMP/upload.zip"
OUT=$(xcrun notarytool submit "$TMP/upload.zip" "${AUTH[@]}" --wait --timeout 1h --output-format json)
echo "$OUT"
ID=$(printf '%s' "$OUT" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
if ! printf '%s' "$OUT" | grep -q '"status" *: *"Accepted"'; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || true   # what Apple rejected, file by file
    echo "notarization failed" >&2; exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"
