# Experiment: DLSS's CNN network (HelixSR) vs MetalFX upscaling

Branch: `experiment/helixsr-vs-metalfx`. Started 2026-11-02.

## Question

How does NVIDIA's DLSS upscaling network (the CNN "Model E", the last one before DLSS 4's transformer)
compare with Apple's MetalFX upscaler on a Mac, in speed and in picture quality, in the same game?

## Setup

- MacBook Pro 16" M4 Max (Mac16,5), 48 GB. Energy Mode High Power, fans at max (see the thermal
  finding: without that the Mac throttles after about 2.5 minutes).
- CrossOver 26.0, bottle `Steam`. The GPTK version is noted for each run.
- Game: The Last of Us Part II Remastered (`tlou-ii.exe`). It supports DLSS and FSR 3.1.

The two paths:

| | A: MetalFX | B: DLSS network |
|---|---|---|
| In-game choice | DLSS | DLSS (caught by HelixSR Scaler) |
| What runs | GPTK's `nvngx` passes DLSS calls to MetalFX's temporal upscaler | HelixSR runs DLSS Model E as D3D12 compute shaders; D3DMetal translates them to Metal |

### HelixSR

- Release 3.1.0 (2026-10-28), `HelixSR-3.1.0.zip`, SHA-256
  `3a1b1ec8b26178cbec3a7bf56b78abf78e236b2062b4cff9cad21993d023bf75` (matches the release's `SHA256SUMS.txt`).
- Freeware, source not published. HelixSR Scaler is OptiScaler (GPL-3.0).
- The zip holds no NVIDIA data. Its setup builds the network on this machine from NVIDIA's DLSS 310.7.0
  DLL (downloaded from NVIDIA), with Python + numpy and Microsoft's DirectX Shader Compiler.
- What the setup builds is NVIDIA- and AMD-derived. It stays in the bottle and in scratch folders, and is
  never committed (same rule as the Lossless files).

## Log

### 2026-11-02

- Downloaded and verified HelixSR 3.1.0. It's built for Windows and Linux (Proton/Wine) on AMD and NVIDIA
  GTX GPUs; nothing in it mentions D3DMetal or Macs.
- How it plugs in: HelixSR Scaler (OptiScaler) goes into the game folder as `dxgi.dll` (or `winmm.dll` /
  `version.dll`), catches the game's DLSS calls and runs HLX DLSS (`HelixSR\helixsr.dll`).
- Building the network on macOS. The Linux wrapper (`helixsr-setup.sh`) refuses anything but x86-64 Linux, so
  `setup/helixsr_setup.py` is run directly:
  - Python 3 venv with numpy 2.5.4.
  - Microsoft's DXC v1.9.2607 for Windows (`dxc_2026_07_29.zip`, SHA-256 checked) through CrossOver's Wine
    (bottle `Steam`), with absolute paths turned into `Z:\` paths, like HelixSR's own Wine wrapper. A cold call
    takes about 10 s while Wine starts; with a Wine process kept running in the bottle, 0.7 s.
  - Options: `--no-fg --no-hlx --no-wave64` (no frame generation, no HLX FSR 4, so no 420 MB AMD driver download;
    Apple GPUs run 32-wide SIMD groups).
- First run: NVIDIA's `nvngx_dlss.dll` 310.7.0 downloaded and checked, then the "fragment tables" step failed:
  `setup/lib/model/launch_synth` is a static Linux x86-64 binary (`Exec format error`). Its source
  (`launch_synth.cpp`, `model.cpp`) ships next to it, and the setup builds it itself when no prebuilt copy is
  there. Built it natively: `clang++ -std=c++17 -O2 model.cpp launch_synth.cpp` (arm64), Linux copy kept as
  `launch_synth.linux`.
- Second run: done in about 2 minutes. `HelixSR/helixsr.dll` now carries the network (223 shaders, 26.6 MB);
  `--status` says `network=1 fg=0 hlx=0`.
- Installed into TLOU2 by hand (its folder already has our LSFG proxy as `version.dll`):
  - `OptiScaler.dll` as `winmm.dll`, `OptiScaler.ini`, the `OptiScaler` folder and the `HelixSR` folder, next to
    `tlou-ii.exe`.
  - Wine override `HKCU\Software\Wine\AppDefaults\tlou-ii.exe\DllOverrides`: `winmm` = `native,builtin`.
  - `OptiScaler.ini`: `LogToFile=true`, `LogLevel=2` (Info), everything else on HelixSR's defaults (`auto`).
  - TLOU2 ships DLSS through Streamline (`sl.interposer.dll`, `sl.dlss.dll`, `nvngx_dlss.dll`). CrossOver redirects
    games' `nvngx.dll` to D3DMetal's own copy, so it's open whether OptiScaler or GPTK gets the DLSS calls.
- First launch (GPTK 3.0, DLSS Quality, 1706×1066 → 2560×1600): OptiScaler loaded as `winmm.dll` next to our
  `version.dll` hook, no crash. But `HelixSR DLSS upscaler: not used`. D3DMetal presents an NVIDIA GPU (vendor
  `10DE`, device `2684`, NVAPI arch `0x190`, because the bottle sets `D3DM_ENABLE_METALFX=1`), so OptiScaler
  treated it as DLSS-capable and passed `CreateFeature` through to the real NGX (`C:\windows\system32\nvngx.dll`,
  i.e. GPTK's MetalFX). So this run was path A, with OptiScaler in between.
- Why, from HelixSR Scaler's source (GPL-3.0, branch `helixsr`): HelixSR is used when `[DLSS] HelixSR` is on, the
  `HelixSR` folder is found and the primary GPU is not `dlssCapable` (`NVNGX_Proxy.h`). `dlssCapable` is only set
  when `[DLSS] Enabled` is on (`IdentifyGpu.cpp`).
- So the A/B is one setting, with OptiScaler loaded in both runs:
  - A (MetalFX): `[DLSS] Enabled=auto`. Log kept as `OptiScaler-runA-metalfx.log` in the game folder.
  - B (HLX DLSS): `[DLSS] Enabled=false`.
- Remote launch for run B failed (user away). `steam.exe -applaunch 2531310` and `steam://rungameid/2531310`
  never reached Steam (nothing in `console_log.txt`). Starting `launcher.exe` directly with `SteamAppId` started
  `tlou-ii.exe` and loaded OptiScaler and our hook, but the game stayed idle with no window and no D3D device for
  4 minutes, so it was stopped. Cause: two Wine sessions for the bottle. An old one (about 11.5 hours) whose
  `steam.exe` spins at about 300% CPU, and a newer one (34 minutes) that the launches went to.
- Side question (not pursued): porting DLSS 4's transformer model instead. HelixSR only has the CNN, so it would
  be a from-scratch PTX → Metal translator plus NVIDIA's launch sequence, about 4× the CNN's compute, and it
  would mean decompiling NVIDIA's DLL. Decision: measure the CNN first; if it's already slower than MetalFX,
  the transformer has no chance.

### 2026-11-02 (later): DLSS's network as native Metal kernels, offline

The user asked to run the network as Metal kernels instead of through D3DMetal, and compare it with MetalFX offline.

- License: HelixSR 3.x's setup scripts and DLL forbid derivative works, so the port uses only HelixSR **1.8.1**'s
  setup folder, which is Apache-2.0: its PTX → HLSL translator, its kernel recipes and its host model (`model.cpp`:
  the launch list, argument blocks, buffer/image roles and weight layout of every frame). No HelixSR DLL is used.
- Build: the 1.8.1 setup (`--keep`, `--separate-files`, no DLL to append into) writes the HLSL of 29 kernels and the
  weights. HLSL → SPIR-V (DXC 1.9 via Wine) → MSL (spirv-cross) → metallib.
- Gaps filled:
  - The four encoder layers (`conv_3x3_pool_*`) are not generated by 1.8.1's setup (its DLL runs them itself).
    Translated from the PTX with 1.8.1's `ptx2hlsl.py`, extended (local copy) with `dp2a` and `cp.async`.
  - DXC's SPIR-V backend crashes on three of them (and on `k5n`, `u8`, `u9`, which this test does not need). Those
    three go DXIL → metallib with Apple's Metal Shader Converter 4.0 beta 3 (top-level argument buffer binding).
  - The host swaps `MV_HIST_READ` / `MV_HIST_WRITE` after each frame (nothing in the plan writes the read side).
- Harness (`bench.mm`): a synthetic scene rendered with Halton jitter and one point sample per pixel (panning photo,
  moving + rotating spoked wheel, static chain-link fence), exact depth and motion, ground truth 8×8 supersampled.
  Both upscalers get the same inputs. HDR path, auto exposure, render-resolution motion vectors.
- MetalFX calibration: best with `jitterOffset = −sample offset`, motion = previous − current position.

First results, M4 Max, 1707×960 → 2560×1440 (DLSS Quality ratio, the `dfn_mid` output kernel):

| | GPU time per frame (median) | PSNR | SSIM |
|---|---|---|---|
| MetalFX temporal | 0.48 ms | 25.4 dB | 0.954 |
| DLSS Model E on Metal (translated) | 27.2 ms | 20.0 dB | 0.837 |
| Bilinear | – | 23.6 dB | 0.923 |

- DLSS quality is not valid yet: below bilinear in every jitter/motion sign combination, with blotches on the static
  fence (zero motion), so it is a numerical bug, most likely in the encoder layers translated for this test.
- Speed by kernel: the four encoder layers take 23.8 ms (e1 13.1, e2 6.1, e3 2.9, e4 1.7). They are a direct PTX
  translation that emulates NVIDIA's tensor-core instructions per thread. HelixSR's tuned kernels for the rest of the
  network take about 2.6 ms together (output kernel `k5` 0.8 ms).
- So even with the encoder tuned to the level of the rest, the network would be about 3–5 ms here: roughly 6–10×
  MetalFX's cost, before any Apple-specific work (`simdgroup_matrix`, fused layers).

Decision (2026-11-02): stopped here, not pursued further. Even tuned, DLSS on Metal would cost 6–10× MetalFX, its
quality was never measured correctly, and NVIDIA's weights cannot ship in the app (users would have to extract them,
which DLSS's license forbids). MetalFX through OptiScaler stays the upscaling path.

## 2026-11-02 (evening): Arm Neural Super Sampling (NSS v1) vs MetalFX

Arm publishes NSS v1, a temporal upscaler: a small U-Net (14 conv layers, ~160K parameters) that predicts per-pixel
filter weights and blend parameters, wrapped in shader pre/post-processing. Weights are on Hugging Face
(`Arm/neural-super-sampling`); the model code and the reference Slang shaders are Apache-2.0
(`arm/neural-graphics-model-gym`).

License of the weights (Arm AI Model Community License v1.0, read in full): use, modify, make derivatives and
distribute commercially, royalty-free. Conditions: ship a copy of the license and Arm's notices, mark modifications,
and carry its acceptable-use clause (no weapons, surveillance, unlawful use, etc.) into our own terms. So unlike DLSS,
NSS could ship in the app. Note: the GLSL deployment shaders in the Hugging Face repo carry a "proprietary,
confidential" header, so the Metal port below is translated from the Apache-2.0 Slang reference instead.

### Step 1: Arm's PyTorch reference on the bench frames

The bench dumps each frame's inputs and MetalFX's output; NSS runs on the same frames through Arm's PyTorch pipeline.
NSS wants motion = current − previous (opposite of MetalFX), jitter as is. MetalFX re-checked at 2×: its calibrated
signs are still its best.

| PSNR / SSIM vs 8×8 supersampled truth | 1707×960 → 2560×1440 (1.5×) | 1280×720 → 2560×1440 (2×) |
|---|---|---|
| NSS high | **28.8 dB / 0.970** | **25.0 dB / 0.932** |
| NSS mid | – | 24.4 dB / 0.937 |
| NSS low | – | 24.1 dB / 0.932 |
| MetalFX | 24.9 dB / 0.949 | 22.6 dB / 0.896 |
| Bilinear | 24.0 dB / 0.933 | 21.7 dB / 0.885 |

NSS resolves the static chain-link fence that MetalFX blurs, and the moving wheel is sharper.

### Step 2: native Metal port ("high" quality)

All passes as Metal compute kernels: input conversion, depth scatter, pre-process, the network, post-process, plus the
per-frame offset LUT on the CPU. Checked stage by stage against the PyTorch reference on the same frame: every
intermediate matched to 4e-4 in float32 (one bug found that way: the nearest-depth offset was packed row/col swapped).

Network kernels, in order of what they bought (2×, whole upscale, M4 Max):

| Version | GPU time | Notes |
|---|---|---|
| naive per-pixel conv, float | 86 ms | correctness baseline |
| `simdgroup_matrix` implicit GEMM, channels-last with zero borders, float | 5.5 ms | |
| half activations/weights (float accumulate), upsample folded into the next conv as four 2×2 phase convs | 4.7 ms | max output change 0.02 |
| color and history as textures, hardware bilinear in post/pre-process | **3.8 ms** | −0.05 dB |

Final, all on the GPU, measured in the bench:

| | quality | GPU time (median) |
|---|---|---|
| 2×: NSS Metal | 25.0 dB / 0.932 | 3.8 ms (network ~2.7, post 0.7, pre 0.3) |
| 2×: MetalFX | 22.6 dB / 0.895 | 0.37 ms |
| 1.5×: NSS Metal | 28.5 dB / 0.966 | 6.6 ms |
| 1.5×: MetalFX | 24.9 dB / 0.946 | 0.48 ms |

The big conv layers run at 6–10 TFLOPS, so at "high" quality the network's floor on M4 Max is about 2 ms at 2×.
The remaining large lever is NSS's "mid"/"low" modes (network at half the input resolution: ~4× less work, −0.6 dB
in step 1), not ported yet.

Metal 4 tensor ops (Metal Performance Primitives `convolution2d`, NHWC/HWIO, matches our layout): compiles and ran
~25% faster than our kernel on the heaviest layer (0.49 vs 0.63 ms), but the output is wrong. Neither offsets nor
sliced tensors fix it; the op is undocumented beta (Xcode 27.2 beta 2). The large speedup from tensor ops is the M5's
GPU neural accelerators, not available on M4.

Conclusion: NSS on Metal beats MetalFX by 2.4 dB (2×) to 3.7 dB (1.5×) and could legally ship, at about 10× MetalFX's
GPU cost for "high". Next: port "mid"/"low", then try it in a real game.

### Step 3: "mid" and "low" modes on Metal

Ported the half-resolution path from the same Apache-2.0 Slang: quarter-resolution depth scatter, a separate low-res
disocclusion pass, half-resolution pre-process (four warped history taps averaged, plus the extra moiré / flat-flicker
detector), 4-bit packed nearest-depth offsets, and the sparse 2×2 filter in post-process (16 KPN channels, 4 taps).
Mid uses Catmull-Rom history sampling, low bilinear. Weights: the published int8 QAT export, run as float.
Checked against the PyTorch reference: pre-process exact; full output within 0.07 (mean 0.0002) once a struct
alignment bug was fixed (an `int2` after an odd number of ints is 8-byte aligned in Metal, not in C++).

| M4 Max, 64 frames | PSNR / SSIM | GPU time (median) | of which network |
|---|---|---|---|
| 2×: NSS high | 25.0 dB / 0.932 | 4.0 ms | 2.7 ms |
| 2×: NSS mid | 24.3 dB / 0.935 | **1.65 ms** | 0.8 ms |
| 2×: NSS low | 24.0 dB / 0.930 | 1.6 ms | 0.8 ms |
| 2×: MetalFX | 22.6 dB / 0.895 | 0.37 ms | |
| 1.5×: NSS high | 28.5 dB / 0.966 | 6.8 ms | 4.7 ms |
| 1.5×: NSS mid | **28.5 dB / 0.974** | **2.4 ms** | 1.3 ms |
| 1.5×: NSS low | 27.8 dB / 0.970 | 2.4 ms | 1.3 ms |
| 1.5×: MetalFX | 24.9 dB / 0.946 | 0.48 ms | |

Mid is the mode to use: +1.7 dB over MetalFX at 2× and +3.6 dB at 1.5×, for about 1.3–1.9 ms more GPU time.
At 1.5× it matches high's PSNR with better SSIM at a third of the cost. Low saves nothing over mid here (they differ
only in history sampling) and loses quality.

Next: try mid in a real game through the hook, which also shows whether the synthetic-scene gains hold up.

### Step 4: NSS in TLOU2, in place of MetalFX

The hook catches `-[<MetalFX temporal scaler> encodeToCommandBuffer:]` (D3DMetal turns the game's DLSS calls into
MetalFX temporal upscaling) and, when the game's profile says `"upscaler": "nss"`, encodes NSS into the same command
buffer instead (`hook/unix/lsfg_nss.m`, kernels in `hook/unix/nss/nss.metal`). Both GPTK paths:

- GPTK 3: Metal 3 command buffer, a plain compute encoder.
- GPTK 4 (what TLOU2 uses here): Metal 4 command buffer. Bindings through an argument table, constants through an
  upload buffer, a barrier before every dispatch, our resources and the game's textures in residency sets, and the
  scaler's fence waited on and updated like MetalFX does. Output is pixel-identical to the Metal 3 path.

What TLOU2 hands MetalFX (GPTK 4.0b3, DLSS): a scaler made at 2560×1600 → 2560×1600 with "input content properties"
(the real render size comes per frame: 1712×1072 at Quality, 1488×928 at Balanced), color RG11B10Float, depth
Depth32Float_Stencil8 (forward, not reversed), motion RG16Float in UV units (scale = render size), a 1×1 R32Float
exposure texture. The DLSS preset (e.g. "Transformer") and sharpness never reach MetalFX, so they don't matter.

Upscale GPU time in game, from Metal 4 command-buffer timestamps around the upscale call (median / p95 per second),
DLSS Balanced, 1488×928 → 2560×1600, ~50 s per mode, game capped at 60 fps:

| Upscaler | Upscale GPU time | Game fps |
|---|---|---|
| MetalFX | 1.34 / 1.37 ms | 60 |
| NSS low | 2.19 / 2.20 ms | 60 |
| NSS mid | 2.23 / 2.24 ms | 60 |
| NSS high | 6.13 / 6.17 ms | 51 |

- NSS mid costs +0.9 ms over MetalFX and keeps the cap; the user's verdict on the image: "looks really good".
- Low costs the same as mid (as in the bench), so mid is the setting to use. High needs GPU headroom.
- The profile setting, quality and the app's "Upscaling" card switch live while the game runs.
