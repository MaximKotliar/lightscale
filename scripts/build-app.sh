#!/bin/bash
# Builds the app ("Lightscale.app", a working name): the setup app plus the CrossOver hook files it installs.
#   scripts/build-app.sh            -> build/Lightscale.app
# Needs: Xcode, Homebrew llvm + lld (for the hook's Windows DLLs). See hook/build.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=Lightscale BUNDLE_ID=dev.lightscale.app   # also first in AppName.bundleIDs; the name lives in Sources/LSFGMetalApp/AppName.swift
APP="$ROOT/build/$NAME.app"
rm -rf "$ROOT/build/LSFG Metal.app"   # this build under its old name

"$ROOT/hook/build.sh" >/dev/null
# Pre-baked kernels from this Mac's Lossless.dll, without Lossless Scaling's numbers (weights and other constants):
# the hook reads those from the user's own copy, so users need no tools. Frame generation (SPIR-V) always; the
# display upscalers (DXBC) too with DXBC_COMPILER (dxbc_compiler from github.com/doitsujin/dxbc-spirv). BAKE=0: none.
# The display upscaler ids are lss-metal's LSSKernels.ids.
DXBC_IDS=133,134,137,138,139,140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,160,161,247
# REUSE_FROM=PATH/Lightscale.app: take the baked kernels and GPTK from that build (a previous release) instead of
# baking them and copying GPTK from this Mac: for CI, which has neither Lossless.dll nor GPTK.
rm -rf "$ROOT/hook/build/baked"
BAKE_ARGS=(--out "$ROOT/hook/build/baked")
[ -n "${DXBC_COMPILER:-}" ] && BAKE_ARGS+=(--dxbc-compiler "$DXBC_COMPILER" --dxbc-ids "$DXBC_IDS")
if [ -n "${REUSE_FROM:-}" ]; then
    [ -f "$REUSE_FROM/Contents/Resources/Hook/baked/dxbc-manifest.json" ] || { echo "no baked kernels in $REUSE_FROM" >&2; exit 1; }
    cp -R "$REUSE_FROM/Contents/Resources/Hook/baked" "$ROOT/hook/build/baked"
    echo "baked kernels reused from $REUSE_FROM"
elif [ "${BAKE:-1}" = 0 ]; then
    echo "building without pre-baked kernels (BAKE=0)"
elif swift run --package-path "$ROOT/vendor/lsfg-metal" -c release -q lsfg-metal bake "${BAKE_ARGS[@]}" >/dev/null 2>&1; then
    if [ -n "${DXBC_COMPILER:-}" ]; then echo "baked kernels included (frame generation, display scaling)"
    else echo "baked kernels included (frame generation only: set DXBC_COMPILER for display scaling)"; fi
else
    rm -rf "$ROOT/hook/build/baked"
    echo "no Lossless.dll or spirv-cross here: building without pre-baked kernels"
fi
swift build --package-path "$ROOT" -c release --product "$NAME" >/dev/null
BIN=$(swift build --package-path "$ROOT" -c release --product "$NAME" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Hook"
cp "$BIN/$NAME" "$APP/Contents/MacOS/$NAME"
for f in lsfghook.dll lsfghook.so lsfghook.placeholder.dll liblsfgbridge.dylib liblssbridge.dylib dinput8.dll version.dll winmm.dll; do
    cp "$ROOT/hook/build/$f" "$APP/Contents/Resources/Hook/"
done
[ -d "$ROOT/hook/build/baked" ] && cp -R "$ROOT/hook/build/baked" "$APP/Contents/Resources/Hook/baked"
cp "$ROOT/hook/build/nss.metallib" "$APP/Contents/Resources/Hook/"
cp -R "$ROOT/hook/build/NSSWeights" "$APP/Contents/Resources/Hook/NSSWeights"   # Arm's license terms ride along
# GPTK versions the app can switch CrossOver between. Each source folder holds external/ and
# wine/ like CrossOver's lib64/apple_gptk. Apple's license allows non-commercial copies that keep
# its notices; these come from this Mac and are never committed. Override with GPTK_SOURCES
# (folders separated by ":").
GPTK_SOURCES=${GPTK_SOURCES:-"$HOME/Applications/CrossOver-GPTK-3.0-backup/apple_gptk:$HOME/Applications/GPTK-4.0b3/lib"}
IFS=: read -ra GPTK_DIRS <<< "$GPTK_SOURCES"
if [ -n "${REUSE_FROM:-}" ]; then
    GPTK_DIRS=()
    if [ -d "$REUSE_FROM/Contents/Resources/GPTK" ]; then
        ditto "$REUSE_FROM/Contents/Resources/GPTK" "$APP/Contents/Resources/GPTK"
        echo "GPTK reused: $(ls "$APP/Contents/Resources/GPTK" | tr '\n' ' ')"
    fi
fi
for src in ${GPTK_DIRS[@]+"${GPTK_DIRS[@]}"}; do
    plist="$src/external/D3DMetal.framework/Versions/A/Resources/Info.plist"
    [ -f "$plist" ] && [ -d "$src/wine" ] || continue
    v=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")
    dst="$APP/Contents/Resources/GPTK/$v"
    mkdir -p "$dst"
    ditto "$src/external" "$dst/external"
    ditto "$src/wine" "$dst/wine"
    # GPTK 4 ships DLSS as nvngx-on-metalfx, but CrossOver redirects games' nvngx.dll to the copy
    # named nvngx (an older nvngx crashes with a newer D3DMetal).
    for ext in x86_64-windows/nvngx%s.dll x86_64-unix/nvngx%s.so; do
        from="$dst/wine/$(printf "$ext" -on-metalfx)" to="$dst/wine/$(printf "$ext" "")"
        if [ -f "$from" ]; then cp "$from" "$to"; fi
    done
    [ -f "$(dirname "$src")/License.rtf" ] && cp "$(dirname "$src")/License.rtf" "$dst/"
    echo "GPTK $v included"
done
# App icon, drawn by scripts/make-icon.swift.
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET/icon_512x512@2x.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
VERSION=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
SHORT_VERSION=$(tr -d '[:space:]' < "$ROOT/VERSION")   # the release version; scripts/release.sh publishes it
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <!-- Game Mode: as MacGamingFix declares it, so macOS accepts the Game Mode Lightscale turns on for the games. -->
    <key>LSSupportsGameMode</key><true/>
    <key>GCSupportsGameMode</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Hardened runtime, no extra entitlements. Not sandboxed: the app edits CrossOver bottles and
# runs CrossOver's wine, spirv-cross and Apple's metal compiler.
# SIGN_IDENTITY="Developer ID Application: …" signs for notarization (scripts/notarize.sh): every Mach-O inside,
# GPTK's Apple-signed ones too (they have no hardened runtime or timestamp), innermost first, then the frameworks
# and the app. Without it, an ad-hoc signature.
IDENTITY=${SIGN_IDENTITY:--}
SIGN=(codesign -f -s "$IDENTITY" --options runtime)
[ "$IDENTITY" != - ] && SIGN+=(--timestamp)
# Ad-hoc: only the hook's own files, GPTK keeps Apple's signature.
INSIDE="$APP/Contents/Resources"; [ "$IDENTITY" = - ] && INSIDE="$APP/Contents/Resources/Hook"
find "$INSIDE" -type f -print0 | xargs -0 file | grep Mach-O | cut -d: -f1 \
    | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2- | while IFS= read -r f; do
    "${SIGN[@]}" "$f" >/dev/null 2>&1 || { echo "can't sign $f" >&2; exit 1; }
done
find "$INSIDE" -name "*.framework" -type d -prune | while IFS= read -r f; do
    "${SIGN[@]}" "$f" >/dev/null 2>&1 || { echo "can't sign $f" >&2; exit 1; }
done
"${SIGN[@]}" "$APP" >/dev/null 2>&1 || { echo "can't sign $APP" >&2; exit 1; }
[ "$IDENTITY" != - ] && echo "signed: $IDENTITY"
echo "$APP"
