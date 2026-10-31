# lsfg-metal

Lossless Scaling frame generation (LSFG) for Windows games running on Apple Silicon through CrossOver / D3DMetal.

Only for people who own [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/). The LSFG shaders are read at runtime from your own `Lossless.dll`. This repo never contains the DLL, the shaders or anything derived from them.

## Architecture

1. **Native Metal network** (current focus): run LSFG's compute passes on Metal. They're auto-translated from the DLL's DXBC shaders first, then the hot passes get hand-written kernels.
2. **Game interposition** (later): hook the game's presentation in CrossOver and insert generated frames.

## Status

| Step | State |
| --- | --- |
| Find `Lossless.dll` in CrossOver bottles (Steam app 993090) | done |
| Read 202 SM5.0 compute shaders and their bindings from the DLL | done |
| DXBC → SPIR-V → MSL → `lsfg.metallib`, all 202 kernels | done |
| Build Metal pipelines for every kernel | done |
| LSFG 3 pass graph, two-frame CLI | in progress |

## Setup

```bash
brew install spirv-cross spirv-tools meson ninja
git clone https://github.com/doitsujin/dxbc-spirv && cd dxbc-spirv
meson setup build -Denable_tools=true -Dbuildtype=release && ninja -C build
```

Install Lossless Scaling with Steam inside a CrossOver bottle, then:

```bash
swift run lsfg-metal locate                       # find Lossless.dll
DXBC_COMPILER=/path/to/dxbc-spirv/build/tools/dxbc_compiler scripts/translate-shaders.sh
swift run lsfg-metal check                        # build all Metal pipelines
```

Translated output is cached in `~/Library/Caches/lsfg-metal/<dll hash>/`.

## Commands

- `locate`: finds Lossless Scaling installs in `~/Library/Application Support/CrossOver/Bottles`, `~/CXPBottles` and any `LSFG_BOTTLES` folders.
- `inspect [--verbose]`: lists the shaders with thread-group size, instruction count and named bindings.
- `dump --out DIR`: writes the shaders as `.dxbc` files. Keep `DIR` outside the repo.
- `check`: builds a Metal pipeline for every translated kernel.

## Notes

- CrossOver 26's `wineloader` is x86_64, hardened runtime, with `disable-library-validation` but no `allow-dyld-environment-variables`, so `DYLD_INSERT_LIBRARIES` is ignored. Part 2 needs another way to inject.
- The ownership check only confirms that Steam's install files exist. It is not a DRM check.
