#!/bin/bash
# NSS performance harness, no game needed: drives a real Metal 4 MetalFX scaler (hook/build/nss_hook_test) with the
# hook loaded, at TLOU2's DLSS Balanced size by default, and prints
#   - upscale GPU time (median of the per-second medians, and of the p95s),
#   - NSS's CPU time per frame on the calling thread,
#   - the per-pass GPU breakdown (LSFG_NSS_PROFILE),
#   - the max pixel difference of the last frame against a reference PNG, if given.
#
#   hook/test/nss_perf.sh OUT_DIR [mid|high|low|metalfx] [REF.png]
# Env: TEST_SIZE (default 1488x928:2560x1600), FRAMES (default 900), PYTHON (with numpy + PIL for the comparison).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$1 mode=${2:-mid} ref=${3:-}
mkdir -p "$out"
size=${TEST_SIZE:-1488x928:2560x1600}
log="$out/$mode.log"
rm -f "$log"
up=nss; [ "$mode" = metalfx ] && up=metalfx
# freshly built kernels, installed weights
nssdir="$out/nss"; mkdir -p "$nssdir"
cp build/nss.metallib "$nssdir/"
for w in nss_high.bin nss_midlow.bin; do ln -sf "$HOME/Library/Application Support/lsfg-metal/nss/$w" "$nssdir/$w"; done
TEST_MTL4=1 TEST_SIZE=$size DYLD_INSERT_LIBRARIES=$PWD/build/lsfghook.so LSFG_UPSCALER=$up LSFG_NSS_QUALITY=$mode \
    LSFG_FG=0 LSFG_NSS_PROFILE=10 LSFG_NSS_DIR="$nssdir" LSFG_LOG="$log" build/nss_hook_test "$out/$mode.png" "${FRAMES:-900}" >/dev/null 2>&1
${PYTHON:-python3} - "$log" "$out/$mode.png" "$ref" "$mode" "$size" <<'EOF'
import re, sys, statistics as st, zlib, struct
log, png, ref, mode, size = sys.argv[1:6]
med, p95, cpu = [], [], []
prof = None
for line in open(log):
    m = re.search(r"upscale GPU \S+(?: \w+)? ([\d.]+) ms \(p95 ([\d.]+), (\d+) frames\)", line)
    if m and int(m.group(3)) >= 20: med.append(float(m.group(1))); p95.append(float(m.group(2)))
    m = re.search(r"(?:NSS|MetalFX) CPU ([\d.]+) ms", line)
    if m: cpu.append(float(m.group(1)))
    if "nss: profile" in line: prof = line.split("nss: profile ", 1)[1].strip()
print(f"{mode} {size}: upscale GPU {st.median(med):.3f} ms (p95 {st.median(p95):.3f}, {len(med)} s)" +
      (f", CPU {st.median(cpu):.3f} ms" if cpu else ""))
if prof: print("  passes:", prof)
if ref:
    try:
        from PIL import Image
        import numpy as np
        a = np.asarray(Image.open(png)).astype(int); b = np.asarray(Image.open(ref)).astype(int)
        d = np.abs(a - b)
        print(f"  vs reference: max diff {d.max()}, pixels differing {(d.max(-1) > 0).mean() * 100:.3f}%")
    except ImportError:
        print("  (no PIL for the image comparison)")
EOF
