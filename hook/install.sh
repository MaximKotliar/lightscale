#!/bin/bash
# Install or remove the lsfg-metal hook for one game in one CrossOver bottle.
#
#   hook/install.sh --bottle ~/CXPBottles/Steam --game-dir "/…/The Witcher 3/bin/x64_dx12" \
#                   --exe witcher3.exe --proxy dinput8
#   hook/install.sh --uninstall (same arguments)
#
# What it changes (all reversible with --uninstall):
#   1. ~/Library/Application Support/lsfg-metal/wine/x86_64-windows/  lsfghook.dll + lsfghook.so
#   2. <bottle>/cxbottle.conf   [Wine] "LibPath" adds that folder to Wine's builtin DLL search path
#                               (backup: cxbottle.conf.lsfg-backup)
#   3. <bottle>/drive_c/windows/system32/lsfghook.dll   Wine placeholder for the builtin
#   4. <game-dir>/<proxy>.dll   forwarding proxy that loads lsfghook.dll into the game
#   5. registry: HKCU\Software\Wine\AppDefaults\<exe>\DllOverrides <proxy> = native,builtin
# Nothing inside CrossOver.app is modified.
set -euo pipefail

CX=${CX:-$HOME/Applications/CrossOver.app/Contents/SharedSupport/CrossOver}
[ -d "$CX" ] || CX=/Applications/CrossOver.app/Contents/SharedSupport/CrossOver
BUILD=$(cd "$(dirname "$0")" && pwd)/build
ROOT="$HOME/Library/Application Support/lsfg-metal"
BEGIN=";; lsfg-metal: begin" END=";; lsfg-metal: end"

uninstall=0 bottle="" game_dir="" exe="" proxy=""
while [ $# -gt 0 ]; do
    case $1 in
        --uninstall) uninstall=1 ;;
        --bottle) bottle=${2%/}; shift ;;
        --game-dir) game_dir=${2%/}; shift ;;
        --exe) exe=$2; shift ;;
        --proxy) proxy=$2; shift ;;
        *) echo "unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[ -f "$bottle/cxbottle.conf" ] && [ -d "$game_dir" ] && [ -n "$exe" ] && [ -n "$proxy" ] || {
    echo "usage: $0 [--uninstall] --bottle DIR --game-dir DIR --exe NAME.exe --proxy dinput8|version" >&2; exit 2; }

conf="$bottle/cxbottle.conf"
placeholder="$bottle/drive_c/windows/system32/lsfghook.dll"
key="HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides"
# The proxy stores "lsfghook.dll" as UTF-16, so match it byte by byte.
is_our_proxy() { [ -f "$1" ] && LC_ALL=C grep -qa 'l.s.f.g.h.o.o.k...d.l.l' "$1"; }
# Adds or removes our marked [Wine] LibPath block; removal restores the file byte for byte.
edit_conf() {
    python3 -I - "$1" "$conf" "$BEGIN" "$END" "${CX_ROOT_LIBPATH:-}" <<'PY'
import sys
mode, path, begin, end, libpath = sys.argv[1:]
text = open(path).read()
if mode == "remove":
    lines = text.split("\n")
    if begin in lines:
        i, j = lines.index(begin), lines.index(end)
        del lines[i:j + 1]
    open(path, "w").write("\n".join(lines))
    sys.exit()
entry = '"LibPath" = "' + libpath + '"'
lines = text.split("\n")
if "[Wine]" in lines:
    i = lines.index("[Wine]")
    lines[i + 1:i + 1] = [begin, entry, end]
    text = "\n".join(lines)
else:
    if not text.endswith("\n"): text += "\n"
    text += "\n".join([begin, "[Wine]", entry, end]) + "\n"
open(path, "w").write(text)
PY
}
wine_reg() { CX_BOTTLE_PATH=$(dirname "$bottle") "$CX/bin/wine" --bottle "$(basename "$bottle")" --wait-children reg "$@" >/dev/null 2>&1; }

if [ $uninstall = 1 ]; then
    if is_our_proxy "$game_dir/$proxy.dll"; then
        rm "$game_dir/$proxy.dll"; echo "removed $game_dir/$proxy.dll"
    fi
    wine_reg delete "$key" /v "$proxy" /f && echo "removed DLL override for $exe"
    rm -f "$placeholder"
    if grep -q "$BEGIN" "$conf"; then edit_conf remove; echo "removed LibPath from $conf"; fi
    echo "uninstalled. ($ROOT is left in place; delete it when no bottle uses it.)"
    exit 0
fi

[ -f "$BUILD/lsfghook.so" ] || { echo "run hook/build.sh first" >&2; exit 1; }
if [ -e "$game_dir/$proxy.dll" ] && ! is_our_proxy "$game_dir/$proxy.dll"; then
    echo "$game_dir/$proxy.dll already exists (another mod?). Not touching it." >&2; exit 1
fi

mkdir -p "$ROOT/wine/x86_64-windows"
cp "$BUILD/lsfghook.dll" "$BUILD/lsfghook.so" "$ROOT/wine/x86_64-windows/"
echo "installed hook to $ROOT"

if ! grep -q "$BEGIN" "$conf"; then
    if grep -qE '^"LibPath"' "$conf"; then
        echo "$conf already sets LibPath; add \"$ROOT\" to it by hand." >&2; exit 1
    fi
    cp "$conf" "$conf.lsfg-backup"
    CX_ROOT_LIBPATH="\${CX_ROOT}/lib:$ROOT" edit_conf add
    echo "added LibPath to $conf (backup: cxbottle.conf.lsfg-backup)"
fi

cp "$BUILD/lsfghook.placeholder.dll" "$placeholder"
cp "$BUILD/$proxy.dll" "$game_dir/$proxy.dll"
wine_reg add "$key" /v "$proxy" /d native,builtin /f
echo "installed $proxy.dll proxy for $exe; log: ~/Library/Logs/lsfg-metal.log"
