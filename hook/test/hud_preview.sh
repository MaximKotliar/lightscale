#!/bin/bash
# Renders the in-game HUD with sample numbers to a PNG (default: build/hud_preview.png).
set -euo pipefail
cd "$(dirname "$0")/.."
I=../vendor/imgui
OUT=build/hud_preview
mkdir -p "$OUT"
clang++ -std=c++17 -O1 -fobjc-arc -mmacosx-version-min=14.0 -I$I -x objective-c++ \
    test/hud_preview.m unix/lsfg_hud.mm $I/backends/imgui_impl_metal.mm \
    $I/imgui.cpp $I/imgui_draw.cpp $I/imgui_tables.cpp $I/imgui_widgets.cpp \
    -framework Foundation -framework Metal -framework QuartzCore -framework IOKit -framework CoreGraphics \
    -framework ImageIO -framework UniformTypeIdentifiers -o "$OUT/hud_preview"
"$OUT/hud_preview" "${1:-build/hud_preview.png}"
