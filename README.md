# Lightscale

*Working name.*

A Mac app that makes Windows games running under CrossOver smoother and sharper on Apple silicon:

- **Frame generation:** Lossless Scaling's LSFG 3.1, running natively on Metal, inserts generated frames (2×–4×).
  Needs your own copy of [Lossless Scaling on Steam](https://store.steampowered.com/app/993090/).
- **Neural upscaling:** in games that use DLSS (which Apple's Game Porting Toolkit turns into MetalFX), Arm's Neural
  Super Sampling can replace MetalFX: a sharper, more stable image at about the same GPU cost.

## What it does

Its data lives in `~/Library/Application Support/Lightscale` and the hook logs to `~/Library/Logs/Lightscale.log`. On first launch the app moves the data from the old `lsfg-metal` folder and leaves a link there, so bottles set up before the rename keep working.

- **First launch:** a one-time setup checklist (Apple silicon, CrossOver, your Steam copy of Lossless Scaling, the frame-generation kernels, the game hook). After that, setup only reappears as a small banner if something breaks, for example after a Lossless Scaling update. **Check Setup…** (⇧⌘,) opens it any time.
- **Games:** Steam games from every CrossOver bottle, plus any `.exe` you add with **Add Game** (remembered across launches; right-click to remove). Install picks the right proxy DLL from the game's imports. Games with anti-cheat, 32-bit games, and folders where another mod uses the proxy name are explained and left alone.
- **Per-game profiles:** frame rate Off / 2× / 4×, performance or quality mode, motion detail and pacing buffer for each game. They're stored in each game's folder (`.lsfg/profile.json`, next to the proxy DLL), so every program the game runs shares them, and the hook picks up changes within a second, even mid-game.
- **GPTK picker:** each game can name the Game Porting Toolkit version it should run with, and the app offers to switch CrossOver to it. CrossOver has one GPTK for all bottles, so a switch applies to every game and needs Steam closed. macOS asks once to let the app change CrossOver (App Management). `scripts/build-app.sh` bundles the versions it finds in `GPTK_SOURCES` (default: `~/Applications/CrossOver-GPTK-3.0-backup/apple_gptk` and `~/Applications/GPTK-4.0b3/lib`). They're never committed. A version CrossOver had that the app doesn't carry is saved to `~/Library/Application Support/Lightscale/gptk` before it's replaced.
- **Now Playing:** while a hooked game runs, its page shows game fps → on-screen fps, frame time and a 60-second chart.

The app isn't sandboxed, because it edits CrossOver bottles and runs CrossOver's `wine`. It's built with the hardened runtime and no extra entitlements.

## Build

```bash
git clone --recurse-submodules https://github.com/MaximKotliar/lightscale
brew install llvm lld@21 spirv-cross spirv-tools   # the hook's Windows DLLs; shader translation
scripts/build-app.sh                               # -> build/Lightscale.app
```

Needs Xcode. The two engines are submodules, pinned to tested commits:

| | |
|---|---|
| [`vendor/lsfg-metal`](https://github.com/MaximKotliar/lsfg-metal) | LSFG 3.1 frame generation on Metal (Swift package; its C API is built for x86_64 for the hook) |
| [`vendor/nss-metal`](https://github.com/MaximKotliar/nss-metal) | Arm Neural Super Sampling on Metal (compiled into the hook) |

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
