// In-game performance HUD, drawn with Dear ImGui into the overlay's drawable as the last step before
// it is presented, so it sits on top of every frame on screen (generated ones included) and is never
// interpolated or upscaled itself. The hook fills a snapshot once a second and reports frame
// intervals as they happen; everything else lives in lsfg_hud.mm.
#pragma once
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>

typedef struct {
    int screenFps, gameFps;                  // frames that reached the display / frames the game made
    double intervalMs, intervalSdMs, intervalMaxMs;   // on-screen frame intervals over the last second
    int dropped;                             // overlay frames the display never showed
    double refreshHz;                        // the display's real refresh rate
    double fgGpuMs;                          // frame generation's command buffer per real frame (0: not running)
    double presentGpuMs;                     // the overlay's own pass per shown frame (copy or scaling, and the HUD)
    double queuedMs;                         // how far ahead of the display frames are queued (latency we add)
    double gpuBusy;                          // 0-1, the game's command buffers
    double upscaleMs;                        // the DLSS replacement's GPU time per frame (0: none ran)
    double memoryMB;
    int thermal;                             // NSProcessInfoThermalState
    char frameGen[64];                       // e.g. "LSFG 2× performance" or "off"
    char upscaler[32];                       // e.g. "NSS mid", "MetalFX" or "" (no DLSS)
    char scaling[96];                        // e.g. "LS1 1728×1117 → 3456×2234" or ""
} LSFGHudSnapshot;

// Running totals since the game started, for the frame-cost graph (the HUD averages them over the last second).
typedef struct {
    long gameFrames;            // frames the game made
    double gpuBusyMs;           // time the game's command buffers ran on the GPU (overlaps counted once)
    double lsfgMs; long lsfgFrames;        // LSFG's GPU time, and the frames it was timed on
    double upscaleMs; long upscaleFrames;  // the DLSS replacement (MetalFX or NSS), inside the game's command buffers
    double displayMs;           // the overlay's passes: copy or scaling, and the HUD
    long displayPasses;         // how many overlay passes ran
    double displayPassMs;       // one overlay pass on its own: the 25th percentile of recent timed passes (0: unknown).
                                // Their mean also counts time the GPU spent on the game's work in between.
    int lsfgInGameWork;         // LSFG runs inside the game's command buffers (Metal 3), so it's part of gpuBusyMs
    long settingsChanges;       // goes up whenever a setting changes: the HUD starts its average over
} LSFGHudTotals;

#ifdef __cplusplus
extern "C" {
#endif
// Implemented by the hook: the totals so far.
void lsfgHudReadTotals(LSFGHudTotals *totals);
// Once a second (stats timer). The HUD reads power itself, every 250 ms while it draws.
void lsfgHudPublish(const LSFGHudSnapshot *snapshot);
// Every frame interval as the display showed it, and every interval between the game's own frames.
void lsfgHudScreenFrame(float ms);
void lsfgHudGameFrame(float ms);
// The colour space the HUD's target is shown in (the overlay's, which is the game's). In HDR (PQ or linear, sRGB
// or BT.2020 primaries) the HUD converts its sRGB colours so they look as they do in SDR; nil or anything else: as is.
// Returns a short name for the log. Any thread.
const char *lsfgHudSetColorSpace(CGColorSpaceRef space);
// Draws into `target` on `cb` (display link thread only). `scale`: pixels per point. `stats`: the performance HUD.
// `badgeAlpha` > 0: the Lightscale icon that shows it's working, at that opacity, `badgePoints` square (in the
// HUD's points, so divide by the HUD's size setting for a fixed size).
void lsfgHudEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target, float scale, bool stats, float badgeAlpha,
                   float badgePoints);
#ifdef __cplusplus
}
#endif
