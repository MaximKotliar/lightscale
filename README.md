# lsfg-metal

Lossless Scaling frame generation (LSFG) for Windows games running on Apple Silicon through CrossOver / D3DMetal.

Only for people who own [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/). The LSFG shaders are read at runtime from your own `Lossless.dll`. This repo never contains the DLL, the shaders or anything derived from them.

## Architecture

1. **Native Metal network** (current focus): run LSFG 3.1's compute passes on Metal. The DLL's own SPIR-V shaders are auto-translated to Metal first; the hot passes get hand-written kernels later.
2. **Game interposition** (later): hook the game's presentation in CrossOver and insert generated frames.

## Status

| Step | State |
| --- | --- |
| Find `Lossless.dll` in CrossOver bottles (Steam app 993090) | done |
| Read the DLL's shaders: 202 DXBC (IDs 101–302) and 98 SPIR-V (IDs 303–400, LSFG 3.1) | done |
| Translate all 300 to one `lsfg.metallib` and build Metal pipelines | done |
| LSFG 3.1 pass graph on Metal (quality and performance modes), two-frame CLI | done |
| Sustained benchmark and Mac feasibility ([docs/performance.md](docs/performance.md)) | done |
| Hand-tuned kernels, game interposition | next |

First results on an M4 Max (synthetic pair: photo panned 16 px plus a disc moving 120 px):

| | PSNR vs true midpoint |
| --- | --- |
| LSFG 3.1 on Metal | 32.4 dB (flow 1.0), 33.0 dB (flow 0.5) |
| 50/50 blend | 21.8 dB |
| Repeat previous frame | 19.6 dB |

Sustained GPU cost per real frame at 2× on an M4 Max: 0.5–2.2 ms at 1080p–1440p, and 1.1–4.5 ms at 4K. CPU cost is about 0.1 ms. Performance mode is about twice as fast as quality mode. Full tables and what they mean for real games: [docs/performance.md](docs/performance.md).

## Setup

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
- `bench PREV NEXT [--frames N] [--sizes WxH,...]`: sustained benchmark across sizes, modes, flow scales and multipliers.

## Credits

The LSFG 3.1 pass graph, shader ID table and constant-buffer layout in `Sources/LSFGCore/LSFG31.swift` follow [lsfg-vk](https://github.com/PancakeTAS/lsfg-vk) at its MIT-licensed revisions (MIT License, Copyright (c) 2025 lsfg-vk). Later lsfg-vk releases use CC BY-NC-ND 4.0, and nothing here comes from them.

Shader translation uses [dxbc-spirv](https://github.com/doitsujin/dxbc-spirv) (MIT) and [SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) (Apache 2.0) as external tools.

## Notes

- CrossOver 26's `wineloader` is x86_64, hardened runtime, with `disable-library-validation` but no `allow-dyld-environment-variables`, so `DYLD_INSERT_LIBRARIES` is ignored. Part 2 needs another way to inject.
- The ownership check only confirms that Steam's install files exist. It is not a DRM check.
