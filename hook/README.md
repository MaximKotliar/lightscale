# CrossOver hook

Runs LSFG frame generation inside a Windows game under CrossOver (D3DMetal), with nothing in `CrossOver.app` modified.

First result: The Witcher 3 (DX12, D3DMetal, capped at 30 fps) on an M4 Max showed a median of 30 real fps → **60 fps on screen**, frame-time spread ±4.6 ms, over a 5-minute session.

## How it gets into the game

`DYLD_INSERT_LIBRARIES` doesn't work: CrossOver's `wineloader` uses the hardened runtime without the entitlement for it. Instead, the hook uses Wine's own way of loading builtin DLLs (the same one CrossOver uses for D3DMetal):

1. **`lsfghook.dll`** is a tiny Windows DLL marked as a Wine builtin. It lives in `~/Library/Application Support/lsfg-metal/wine/x86_64-windows/`, which the bottle's `cxbottle.conf` adds to Wine's DLL search path (`[Wine] LibPath`). A placeholder copy in the bottle's `system32` makes Wine look it up there.
2. When it loads, Wine loads its native side, **`lsfghook.so`** (x86_64 macOS code, run under Rosetta like `wineloader`), into the game process.
3. **A proxy DLL in the game folder** triggers that: `dinput8.dll` or `version.dll`. It forwards every call to the real system DLL and also loads `lsfghook.dll`. A per-game registry override (`<proxy> = native,builtin`) makes Wine use it.

## How frames are generated and shown

D3DMetal draws each finished frame into a drawable with one render pass, commits that command buffer, then calls `-[CAMetalDrawable present]`. The hook:

- **On commit:** appends to that same command buffer, so the GPU runs it after the game's work. It copies the frame into LSFG, runs LSFG 3.1 (the `LSFGBridge` engine, `liblsfgbridge.dylib`, with shaders from your own `Lossless.dll`), and copies the real and generated frames into a small ring of textures.
- **On present:** doesn't present the game's drawable. The game gets it back immediately, so frame generation can never slow the game down.
- **On our own overlay layer** (a `CAMetalLayer` on top of the game's layer): once the GPU finishes, the generated frames and the real one are queued evenly across one real-frame interval, on a steady cadence with an 8 ms buffer, so the game's frame-time jitter doesn't reach the screen. A `CAMetalDisplayLink` on its own thread shows the newest frame due at each display refresh.
- **2× or 4×:** with 4× the hook generates three frames per real one. When the display can't show them all (60 Hz, or Low Power Mode, which caps the display at 60 Hz), it picks evenly spaced frames, so 4× falls back to a clean 2× instead of dropping frames.

Things that didn't work, and why (useful for other games):

| Approach | Problem |
| --- | --- |
| Chained `presentAfterMinimumDuration:` | Display rounding queued frames, the game waited for drawables, and it throttled itself (30 → 12–15 fps). |
| `presentAtTime:` from `present` | Witcher 3 is GPU-bound: frames weren't finished by their time, and the display dropped the generated ones. |
| Presenting the game's own drawables | Only 3 drawables, held until the compositor showed them (~25 ms), so the game waited in `nextDrawable`. |

## Setup

Requirements: Lossless Scaling owned and installed through Steam in a CrossOver bottle, and the shaders translated once (`scripts/translate-shaders.sh`, see the main README).

```bash
hook/build.sh
hook/install.sh --bottle ~/CXPBottles/Steam \
    --game-dir ~/"CXPBottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/The Witcher 3/bin/x64_dx12" \
    --exe witcher3.exe --proxy dinput8
```

Pick the proxy from the game exe's imports (`llvm-objdump -p game.exe | grep 'DLL Name'`): `dinput8` or `version`. The installer refuses to overwrite a proxy DLL that isn't ours (another mod).

`--uninstall` with the same arguments removes everything and restores `cxbottle.conf` byte for byte.

Cap the game at half your display's refresh rate (30 on 60 Hz, 60 on 120 Hz, or 30 on 120 Hz) for perfectly even pacing.

## Settings

Per-game profiles live in `~/Library/Application Support/lsfg-metal/profiles.json`, and LSFG Metal.app edits them. The hook checks the file once a second while the game runs: on/off and the pacing buffer apply at once; multiplier, mode and motion detail rebuild the LSFG context in the background (0.05–0.2 s) and swap it in on the next frame, whose output only primes the new context:

```json
{ "default": { "enabled": true, "multiplier": 2, "performance": true, "flowScale": 1.0, "bufferMs": 8 },
  "games": { "witcher3.exe": { "enabled": true, "multiplier": 4, "performance": false, "flowScale": 0.75, "bufferMs": 8 } },
  "custom": [] }
```

The hook reads them when the game starts, matching on the exe name. These environment variables override them (for example in the bottle's `[EnvironmentVariables]`):

| Variable | Default | Effect |
| --- | --- | --- |
| `LSFG_ENABLE=0` | on | Load, but install no hooks |
| `LSFG_FG=0` | on | Observe only (logging), no frame generation |
| `LSFG_MULTIPLIER` | 2 | Frames on screen per real frame: 2 or 4 (3 also works) |
| `LSFG_PERFORMANCE=0` | performance | LSFG quality mode |
| `LSFG_FLOW_SCALE` | 1.0 | Motion-estimation resolution, 0.25–1.0 |
| `LSFG_BUFFER_MS` | 8 | Scheduling headroom: higher is smoother, lower has less lag |
| `LSFG_TRACE=1` | off | Per-frame timing for the first frames |
| `LSFG_LOG` | `~/Library/Logs/lsfg-metal.log` | Log file; every second it records presents, generated frames, on-screen fps, frame-time spread and drops; every 10 s the process's memory footprint |

## Limits

- **2× only** for now (one generated frame per real frame).
- **HUD and UI are interpolated with the scene.** LSFG only sees finished frames.
- **Latency:** each real frame is shown about half a frame plus 8 ms later than without frame generation.
- **Resolution changes:** if the game changes resolution mid-session, frame generation switches off until restart.
- **Only one game tested** (The Witcher 3 under D3DMetal). Other presentation paths (`presentDrawable:` on a command buffer, Metal 4 `signalDrawable:`) are logged but not taken over yet.
- **64-bit games only.** Never use it with online games that have anti-cheat.

## Tests

- `build/bridge_test`: runs the LSFG engine under Rosetta on synthetic RGB10A2 frames.
- `build/fake_game`: imitates D3DMetal's present pattern in a window. Load the hook with `DYLD_INSERT_LIBRARIES=$PWD/build/lsfghook.so`. `FAKE_FPS`, `FAKE_JITTER=1` and `FAKE_GPU_MS` simulate real-game conditions. `FAKE_THREAD=1` renders from a plain thread, like Wine's (`FAKE_THREAD=2`: without a per-frame autorelease pool), and `FAKE_SECONDS` sets how long it runs.
- `build/present_order`: shows which presentation patterns Core Animation drops.
