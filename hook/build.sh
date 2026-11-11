#!/bin/bash
# Builds the CrossOver hook: Windows PE side (clang + lld-link, no SDK) and
# native x86_64 macOS side (wineloader runs under Rosetta).
set -euo pipefail
cd "$(dirname "$0")"
LLVM=${LLVM:-/opt/homebrew/opt/llvm/bin}
LLD=${LLD:-/opt/homebrew/opt/lld@21/bin}
OUT=${OUT:-build}
mkdir -p "$OUT/obj"

for lib in kernel32 ntdll; do
    "$LLVM/llvm-dlltool" -m i386:x86-64 -d "pe/$lib.def" -l "$OUT/obj/$lib.lib"
done
CFLAGS=(--target=x86_64-pc-windows-msvc -O2 -ffreestanding -fno-stack-protector -mno-stack-arg-probe -Wall -Wextra)
"$LLVM/clang" "${CFLAGS[@]}" -c pe/lsfghook.c -o "$OUT/obj/lsfghook.obj"
"$LLVM/clang" "${CFLAGS[@]}" -c pe/lsfgtest.c -o "$OUT/obj/lsfgtest.obj"
"$LLVM/clang" "${CFLAGS[@]}" -c pe/vertest.c -o "$OUT/obj/vertest.obj"
for proxy in version dinput8 winmm; do
    python3 -I pe/gen_proxy.py $proxy "$OUT/obj/$proxy.c"
    "$LLVM/clang" "${CFLAGS[@]}" -Ipe -c "$OUT/obj/$proxy.c" -o "$OUT/obj/$proxy.obj"
done
"$LLD/lld-link" /nologo /dll /nodefaultlib /entry:DllMain /out:"$OUT/lsfghook.dll" \
    "$OUT/obj/lsfghook.obj" "$OUT/obj/kernel32.lib" "$OUT/obj/ntdll.lib"
for proxy in version dinput8 winmm; do
    "$LLD/lld-link" /nologo /dll /nodefaultlib /entry:DllMain /out:"$OUT/$proxy.dll" \
        "$OUT/obj/$proxy.obj" "$OUT/obj/kernel32.lib"
done
rm -f "$OUT"/*.lib
"$LLD/lld-link" /nologo /nodefaultlib /entry:start /subsystem:console /out:"$OUT/lsfgtest.exe" \
    "$OUT/obj/lsfgtest.obj" "$OUT/obj/kernel32.lib"

"$LLD/lld-link" /nologo /nodefaultlib /entry:start /subsystem:console /out:"$OUT/vertest.exe" \
    "$OUT/obj/vertest.obj" "$OUT/obj/kernel32.lib"

# Mark lsfghook.dll as a Wine builtin: "Wine builtin DLL" right after the DOS header.
printf 'Wine builtin DLL\0' | dd of="$OUT/lsfghook.dll" bs=1 seek=64 conv=notrunc status=none
# ...and a placeholder copy for the bottle's system32, which makes Wine look up the real one.
cp "$OUT/lsfghook.dll" "$OUT/lsfghook.placeholder.dll"
printf 'Wine placeholder DLL\0' | dd of="$OUT/lsfghook.placeholder.dll" bs=1 seek=64 conv=notrunc status=none

# NSS upscaler: the NSSMetal library from vendor/nss-metal, compiled into the hook, and its kernels.
NSS=${NSS_METAL:-../vendor/nss-metal}
# In-game HUD: Dear ImGui (vendor/imgui, MIT) and its Metal backend, compiled in as C++.
IMGUI=${IMGUI:-../vendor/imgui}
HUD_SRC=(unix/lsfg_hud.mm "$IMGUI/backends/imgui_impl_metal.mm" "$IMGUI/imgui.cpp" "$IMGUI/imgui_draw.cpp"
         "$IMGUI/imgui_tables.cpp" "$IMGUI/imgui_widgets.cpp")
HUD_OBJ=()
for src in "${HUD_SRC[@]}"; do
    obj="$OUT/obj/$(basename "$src").o"
    clang++ -arch x86_64 -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.0 -I"$IMGUI" -c "$src" -o "$obj"
    HUD_OBJ+=("$obj")
done
clang -arch x86_64 -dynamiclib -O2 -Wall -fobjc-arc -mmacosx-version-min=14.0 -Wno-unguarded-availability-new \
    -I"$NSS/Sources/NSSMetal/include" \
    -framework AppKit -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework IOKit \
    -framework ImageIO -framework UniformTypeIdentifiers -lc++ \
    -o "$OUT/lsfghook.so" unix/lsfghook_unix.m "$NSS/Sources/NSSMetal/NSSUpscaler.m" "${HUD_OBJ[@]}"
"$NSS/scripts/build-metallib.sh" "$OUT/nss.metallib"
# Arm's NSS weights with their license, notices and acceptable-use terms (the app installs them next to the kernels)
rm -rf "$OUT/NSSWeights" && cp -R "$NSS/Sources/NSSMetal/Weights" "$OUT/NSSWeights"
codesign -s - -f "$OUT/lsfghook.so" 2>/dev/null

# LSFG engine for the hook: lsfg-metal's C API (vendor/lsfg-metal), built for x86_64 like wineloader.
LSFG=${LSFG_METAL:-../vendor/lsfg-metal}
(cd "$LSFG" && swift build -c release --arch x86_64 --product LSFGBridge >/dev/null)
cp "$(cd "$LSFG" && swift build -c release --arch x86_64 --product LSFGBridge --show-bin-path)/libLSFGBridge.dylib" "$OUT/liblsfgbridge.dylib"
codesign -s - -f "$OUT/liblsfgbridge.dylib" 2>/dev/null

# Lossless Scaling's spatial upscalers for the hook: lss-metal's C API (vendor/lss-metal), x86_64 too.
LSS=${LSS_METAL:-../vendor/lss-metal}
(cd "$LSS" && swift build -c release --arch x86_64 --product LSSBridge >/dev/null)
cp "$(cd "$LSS" && swift build -c release --arch x86_64 --product LSSBridge --show-bin-path)/libLSSBridge.dylib" "$OUT/liblssbridge.dylib"
codesign -s - -f "$OUT/liblssbridge.dylib" 2>/dev/null
echo "built: $(ls "$OUT" | grep -v obj | tr '\n' ' ')"
