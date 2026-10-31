#!/bin/bash
# Builds "LSFG Metal.app": the setup app plus the CrossOver hook files it installs.
#   scripts/build-app.sh            -> build/LSFG Metal.app
# Needs: Xcode, Homebrew llvm + lld (for the hook's Windows DLLs). See hook/build.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/LSFG Metal.app"

"$ROOT/hook/build.sh" >/dev/null
# Pre-baked kernels (no weights inside) from this Mac's Lossless.dll, if there is one.
rm -rf "$ROOT/hook/build/baked"
if swift run --package-path "$ROOT" -c release -q lsfg-metal bake --out "$ROOT/hook/build/baked" >/dev/null 2>&1; then
    echo "baked kernels included"
else
    rm -rf "$ROOT/hook/build/baked"
    echo "no Lossless.dll or spirv-cross here: building without pre-baked kernels (the app translates on first run)"
fi
swift build --package-path "$ROOT" -c release --product LSFGMetal >/dev/null
BIN=$(swift build --package-path "$ROOT" -c release --product LSFGMetal --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Hook"
cp "$BIN/LSFGMetal" "$APP/Contents/MacOS/LSFGMetal"
for f in lsfghook.dll lsfghook.so lsfghook.placeholder.dll liblsfgbridge.dylib dinput8.dll version.dll; do
    cp "$ROOT/hook/build/$f" "$APP/Contents/Resources/Hook/"
done
[ -d "$ROOT/hook/build/baked" ] && cp -R "$ROOT/hook/build/baked" "$APP/Contents/Resources/Hook/baked"
VERSION=$(git -C "$ROOT" describe --always --dirty 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LSFG Metal</string>
    <key>CFBundleDisplayName</key><string>LSFG Metal</string>
    <key>CFBundleIdentifier</key><string>dev.lsfg-metal.setup</string>
    <key>CFBundleExecutable</key><string>LSFGMetal</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# Hardened runtime, no extra entitlements. Not sandboxed: the app edits CrossOver bottles and
# runs CrossOver's wine, spirv-cross and Apple's metal compiler.
codesign -s - -f --options runtime "$APP/Contents/Resources/Hook/lsfghook.so" "$APP/Contents/Resources/Hook/liblsfgbridge.dylib" 2>/dev/null
codesign -s - -f --options runtime "$APP" 2>/dev/null
echo "$APP"
