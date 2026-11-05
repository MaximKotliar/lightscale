#!/bin/bash
# Publishes the version in VERSION as GitHub release v<version>: builds the app with every kernel, zips it, signs
# the zip (scripts/sign-update.swift, key in ~/.config/lightscale) and uploads both. Installed apps find it through
# the GitHub API and update themselves (Sources/LSFGMetalApp/Domain/Updater.swift).
#   DXBC_COMPILER=/path/to/dxbc_compiler scripts/release.sh
# NOTES=FILE: release notes (default: the commit subjects since the previous release).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
die() { echo "release: $*" >&2; exit 1; }

V=$(tr -d '[:space:]' < VERSION)
[ -z "$(git status --porcelain)" ] || die "commit everything first"
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse @{u})" ] || die "push first (HEAD isn't origin's)"
! git ls-remote --exit-code --tags origin "v$V" >/dev/null || die "v$V is already released: bump VERSION"
[ -n "${DXBC_COMPILER:-}" ] || die "set DXBC_COMPILER: the display-scaling kernels are part of every release"

scripts/build-app.sh
[ -f build/Lightscale.app/Contents/Resources/Hook/baked/dxbc-manifest.json ] || die "the build has no display-scaling kernels"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/Lightscale.app/Contents/Info.plist)" = "$V" ] || die "version mismatch"

ZIP=build/Lightscale-$V.zip
rm -f "$ZIP" "$ZIP.sig"
ditto -c -k --sequesterRsrc --keepParent build/Lightscale.app "$ZIP"
swift scripts/sign-update.swift sign "$ZIP"
swift scripts/sign-update.swift verify "$ZIP"

NOTES_FILE=$(mktemp)
if [ -n "${NOTES:-}" ]; then cp "$NOTES" "$NOTES_FILE"
else
    PREV=$(git describe --tags --abbrev=0 HEAD^ 2>/dev/null || true)
    git log --format='- %s' ${PREV:+"$PREV..HEAD"} > "$NOTES_FILE"
fi
gh release create "v$V" "$ZIP" "$ZIP.sig" --target "$(git rev-parse HEAD)" --title "Lightscale $V" --notes-file "$NOTES_FILE"
git fetch -q --tags origin
