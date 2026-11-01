# lsfg-metal

Lossless Scaling frame generation (LSFG) for Windows games running on Apple Silicon through CrossOver / D3DMetal.

Only for people who own [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/). The LSFG shaders are read at runtime from your own `Lossless.dll`. This repo never contains the DLL, the shaders or anything derived from them.

## Architecture

1. **Native Metal network** (current focus): run LSFG 3.1's compute passes on Metal. The DLL's own SPIR-V shaders are auto-translated to Metal first; the hot passes get hand-written kernels later.
2. **Game interposition**: a hook loaded into the game under CrossOver that inserts generated frames into its presentation. See [hook/README.md](hook/README.md).

## Status

| Step | State |
| --- | --- |
| Find `Lossless.dll` in CrossOver bottles (Steam app 993090) | done |
| Read the DLL's shaders: 202 DXBC (IDs 101–302) and 98 SPIR-V (IDs 303–400, LSFG 3.1) | done |
| Translate all 300 to one `lsfg.metallib` and build Metal pipelines | done |
| LSFG 3.1 pass graph on Metal (quality and performance modes), two-frame CLI | done |
| Sustained benchmark and Mac feasibility ([docs/performance.md](docs/performance.md)) | done |
| Real game footage, TLOU2 ([docs/real-footage.md](docs/real-footage.md)) | done: beats a blend on 230/235 frames by about 8–9 dB |
| CrossOver hook: injection, D3DMetal present path, frame insertion ([hook/README.md](hook/README.md)) | working: Witcher 3, 30 → 60 fps on screen |
| Setup app: checks, shader translation, install into games, settings, live stats | done |
| Kernel optimization: concurrent pass scheduling, 10–25% faster, identical output | done |
| Pre-baked kernels with weights from the user's DLL; app redesign with per-game profiles | done |
| 3×/4× in the hook, HUD handling, more games | next |

First results on an M4 Max (synthetic pair: photo panned 16 px plus a disc moving 120 px):

| | PSNR vs true midpoint |
| --- | --- |
| LSFG 3.1 on Metal | 32.4 dB (flow 1.0), 33.0 dB (flow 0.5) |
| 50/50 blend | 21.8 dB |
| Repeat previous frame | 19.6 dB |

Sustained GPU cost per real frame at 2× on an M4 Max: 0.4–2.0 ms at 1080p–1440p after scheduling optimizations (10–25% faster than the first port), and 1.1–4.5 ms at 4K before them. CPU cost is about 0.1 ms. Performance mode is about twice as fast as quality mode. Full tables and what they mean for real games: [docs/performance.md](docs/performance.md).

## App

`scripts/build-app.sh` builds **LSFG Metal.app** (`build/LSFG Metal.app`):

- **First launch:** a one-time setup checklist (Apple silicon, CrossOver, your Steam copy of Lossless Scaling, the frame-generation kernels, the game hook). After that, setup only reappears as a small banner if something breaks, for example after a Lossless Scaling update. **Check Setup…** (⇧⌘,) opens it any time.
- **Games:** Steam games from every CrossOver bottle, plus any `.exe` you add with **Add Game** (remembered across launches; right-click to remove). Install picks the right proxy DLL from the game's imports. Games with anti-cheat, 32-bit games, and folders where another mod uses the proxy name are explained and left alone.
- **Per-game profiles:** frame rate Off / 2× / 4×, performance or quality mode, motion detail and pacing buffer for each game. They're stored in `~/Library/Application Support/lsfg-metal/profiles.json` and read by the hook, which picks up changes within a second, even mid-game.
- **Now Playing:** while a hooked game runs, its page shows game fps → on-screen fps, frame time and a 60-second chart.

The app isn't sandboxed, because it edits CrossOver bottles and runs CrossOver's `wine`. It's built with the hardened runtime and no extra entitlements.

### Pre-baked kernels, weights from your DLL

`lsfg-metal bake --out DIR` compiles every LSFG 3.1 shader once with all floating-point constants (the weights) lifted out into zeroed Metal function constants. The resulting `lsfg-skeleton.metallib` plus `manifest.json` (a structure hash per kernel) contain no weights. At runtime the engine reads the constants from the user's own `Lossless.dll`, checks each shader's structure hash, and specializes the pipelines with `MTLFunctionConstantValues`:

- **Same speed** as locally translated kernels (within ±3%). Rounding differs by at most 1/255.
- **Fast startup:** about 0.3 s cold, about 0.07 s once Metal has cached the pipelines.
- **No developer tools for users:** they don't need `spirv-cross` or Xcode. Only if a Lossless Scaling update changes a shader's structure does the app fall back to a one-time local build.

`scripts/build-app.sh` bakes into the app bundle when it finds a `Lossless.dll`. The skeleton contains no weights, but it's still a translation of Lossless Scaling's shader code, so it's kept out of git. Distributing an app bundle that contains it is a separate decision.

## Setup (command line)

```bash
brew install spirv-cross spirv-tools
```

LSFG 3.1 only needs the SPIR-V shaders. To also translate the DXBC ones (upscalers, older LSFG), build [dxbc-spirv](https://github.com/doitsujin/dxbc-spirv) with `-Denable_tools=true` and set `DXBC_COMPILER` to its `dxbc_compiler`.

Install Lossless Scaling with Steam inside a CrossOver bottle, then:

```bash
swift run lsfg-metal locate                       # find Lossless.dll
scripts/translate-shaders.sh                      # → ~/Library/Caches/lsfg-metal/<dll hash>/
swift run lsfg-metal check                        # build all Metal pipelines
swift run -c release lsfg-metal generate prev.png next.png -o mid.png
```

Translated output is cached in `~/Library/Caches/lsfg-metal/<dll hash>/`.

## Commands

- `locate`: finds Lossless Scaling installs in `~/Library/Application Support/CrossOver/Bottles`, `~/CXPBottles` and any `LSFG_BOTTLES` folders.
- `inspect [--verbose]`: lists the shaders with thread-group size, instruction count and named bindings.
- `dump --out DIR`: writes the shaders as `.dxbc` files. Keep `DIR` outside the repo.
- `check`: builds a Metal pipeline for every translated kernel.
- `generate PREV NEXT -o OUT.png [--multiplier N] [--flow-scale F] [--fp32] [--performance] [--runs N]`: writes the generated frame(s) between two images. With `--multiplier 3` or more it writes `OUT.1.png`, `OUT.2.png`, and so on.
- `eval VIDEO|DIR [--start S] [--count N] [--max-width W] [--flow-scale F] [--performance] [--samples DIR]`: scores LSFG on real footage. It keeps every other frame of a 60 fps recording as the "real" 30 fps stream, generates the frame in between, and compares it with the frame the game actually rendered (PSNR and SSIM, against a blend and a repeat). `--samples` writes truth | generated | blend images.
- `profile PREV NEXT [--size WxH] [--performance] [--flow-scale F]`: GPU time per pass.
- `bench PREV NEXT [--frames N] [--sizes WxH,...]`: sustained benchmark across sizes, modes, flow scales and multipliers.

## Credits

The LSFG 3.1 pass graph, shader ID table and constant-buffer layout in `Sources/LSFGCore/LSFG31.swift` follow [lsfg-vk](https://github.com/PancakeTAS/lsfg-vk) at its MIT-licensed revisions (MIT License, Copyright (c) 2025 lsfg-vk). Later lsfg-vk releases use CC BY-NC-ND 4.0, and nothing here comes from them.

Shader translation uses [dxbc-spirv](https://github.com/doitsujin/dxbc-spirv) (MIT) and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache 2.0) as external tools.

## Notes

- CrossOver 26's `wineloader` is x86_64, hardened runtime, with `disable-library-validation` but no `allow-dyld-environment-variables`, so `DYLD_INSERT_LIBRARIES` is ignored. The hook gets in through Wine's builtin-DLL mechanism instead (see [hook/README.md](hook/README.md)).
- The ownership check only confirms that Steam's install files exist. It is not a DRM check.
