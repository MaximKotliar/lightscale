# Lightscale

*Working name.*

A Mac app that makes Windows games running under CrossOver smoother and sharper on Apple silicon:

- **Frame generation:** Lossless Scaling's LSFG 3.1, running natively on Metal, inserts generated frames (2×–4×).
  Needs your own copy of [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/).
- **Scaling, in any game:** run the game at a lower resolution and Lightscale scales its frames up to the window with
  Lossless Scaling's own upscalers (LS1, FSR 1, BCAS, bicubic) or nearest neighbour, like Lossless Scaling does on
  Windows. Works with or without frame generation.
- **Neural upscaling:** in games that use DLSS (which Apple's Game Porting Toolkit turns into MetalFX), Arm's
  [Neural Super Sampling](https://huggingface.co/Arm/neural-super-sampling) can replace MetalFX: a sharper, more stable
  image at about the same GPU cost. ([Paper](https://huggingface.co/Arm/neural-super-sampling/blob/main/2025-neural-super-sampling.pdf),
  [Arm's NSS guide](https://developer.arm.com/documentation/111009/latest/); the Metal port is
  [nss-metal](https://github.com/MaximKotliar/nss-metal).)

## What it does

Its data lives in `~/Library/Application Support/Lightscale` and the hook logs to `~/Library/Logs/Lightscale.log`. On first launch the app moves the data from the old `lsfg-metal` folder and leaves a link there, so bottles set up before the rename keep working.

- **First launch:** a one-time setup checklist (Apple silicon, CrossOver, the game hook; optionally your Steam copy of Lossless Scaling, with the frame-generation and display-scaling kernels for it). Without Lossless Scaling, NSS/MetalFX and the HUD still work; frame generation and display scaling say they need it. After that, setup only reappears as a small banner if something breaks, for example after a Lossless Scaling update. **Check Setup…** (⇧⌘,) opens it any time.
- **Games:** Steam games from every CrossOver bottle, plus any `.exe` you add with **Add Game** (remembered across launches; right-click to remove). Install picks the right proxy DLL from the game's imports. Games with anti-cheat, 32-bit games, and folders where another mod uses the proxy name are explained and left alone.
- **Per-game profiles:** frame rate Off / 2× / 4×, performance or quality mode, motion detail and pacing buffer for each game. They're stored in each game's folder (`.lsfg/profile.json`, next to the proxy DLL), so every program the game runs shares them, and the hook picks up changes within a second, even mid-game.
- **GPTK picker:** each game can name the Game Porting Toolkit version it should run with, and the app offers to switch CrossOver to it. CrossOver has one GPTK for all bottles, so a switch applies to every game and needs Steam closed. macOS asks once to let the app change CrossOver (App Management). `scripts/build-app.sh` bundles the versions it finds in `GPTK_SOURCES` (default: `~/Applications/CrossOver-GPTK-3.0-backup/apple_gptk` and `~/Applications/GPTK-4.0b3/lib`). They're never committed. A version CrossOver had that the app doesn't carry is saved to `~/Library/Application Support/Lightscale/gptk` before it's replaced.
- **Upscaling:** two settings that stack. *DLSS Replacement* (games with DLSS) runs MetalFX or NSS in place of the game's DLSS. *Display Scaling* (any game) scales the finished frames up to the screen with Lossless Scaling's LS1, FSR, BCAS, bicubic or nearest.
- **Performance HUD:** a per-game switch for an overlay the hook draws in the game's top-left corner, on the final image of every frame on screen (after frame generation and scaling, so it's never interpolated). It shows fps on screen and the game's own fps, a frame-time graph, GPU time for frame generation, the DLSS replacement and the display pass, added latency, GPU load, power draw and memory, and a line on what limits the frame rate. It's drawn with [Dear ImGui](https://github.com/ocornut/imgui) (MIT, `vendor/imgui`).

The app isn't sandboxed, because it edits CrossOver bottles and runs CrossOver's `wine`. It's built with the hardened runtime and no extra entitlements.

## Build

```bash
git clone --recurse-submodules https://github.com/MaximKotliar/lightscale
brew install llvm lld@21 spirv-cross spirv-tools   # the hook's Windows DLLs; kernel baking
DXBC_COMPILER=/path/to/dxbc-spirv/build/tools/dxbc_compiler scripts/build-app.sh   # -> build/Lightscale.app
```

Needs Xcode. The two engines are submodules, pinned to tested commits:

| | |
|---|---|
| [`vendor/lsfg-metal`](https://github.com/MaximKotliar/lsfg-metal) | LSFG 3.1 frame generation on Metal (Swift package; its C API is built for x86_64 for the hook) |
| [`vendor/nss-metal`](https://github.com/MaximKotliar/nss-metal) | Arm Neural Super Sampling on Metal (compiled into the hook) |
| [`vendor/lss-metal`](https://github.com/MaximKotliar/lss-metal) | Lossless Scaling's spatial upscalers on Metal (its C API is built for x86_64 for the hook) |

The build bakes every kernel from this Mac's Lossless.dll (`lsfg-metal bake`): frame generation (SPIR-V) and, with
`DXBC_COMPILER` set ([dxbc-spirv](https://github.com/doitsujin/dxbc-spirv)), the display upscalers (DXBC). Baked
kernels hold none of Lossless Scaling's numbers: weights and other constants are read from each user's own DLL when
a game loads them, so users need no tools and nothing is built on their Mac. They fit the Lossless Scaling versions
they were baked from; an update that changes a shader's structure needs a new build of the app.

Update one with `git -C vendor/nss-metal pull origin main` and commit the new pointer.

NSS ships with Arm's trained weights (from nss-metal). They're licensed by Arm under the Arm AI Model Community
License, not with the rest of the app: using NSS means agreeing to its acceptable-use terms, which the app shows next
to the NSS setting and under Help.

## How the hook works

[hook/README.md](hook/README.md): how it gets into the game through Wine's builtin-DLL mechanism, inserts frames
into D3DMetal's presentation, and swaps MetalFX for NSS.

Notes:

- CrossOver 26's `wineloader` is x86_64, hardened runtime, with `disable-library-validation` but no `allow-dyld-environment-variables`, so `DYLD_INSERT_LIBRARIES` is ignored. The hook gets in through Wine's builtin-DLL mechanism instead.
- The ownership check only confirms that Steam's install files exist. It is not a DRM check.
