// In-game performance HUD (see lsfg_hud.h). Dear ImGui (vendor/imgui, MIT) with its Metal backend; no
// platform backend: the HUD takes no input, so only the display size and the clock are fed in.
#import "lsfg_hud.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <math.h>
#include <os/lock.h>
#include "imgui.h"
#include "backends/imgui_impl_metal.h"

#pragma mark - Data

// Frame-interval history for the graph: written from the threads that see the frames, read when drawing.
// A torn read only misplaces one point of the graph, so the rings take no lock.
enum { kHistory = 240 };
struct Ring {
    float values[kHistory] = {};
    std::atomic<unsigned> next{0};
    void push(float v) { values[next.fetch_add(1, std::memory_order_relaxed) % kHistory] = v; }
    // i-th value, oldest first; 0 where there is none yet.
    float at(int i) const {
        unsigned n = next.load(std::memory_order_relaxed);
        if (n < (unsigned)kHistory && (unsigned)i < kHistory - n) return 0;
        return values[(n + i) % kHistory];
    }
};
static Ring screenRing, gameRing;

static os_unfair_lock snapLock = OS_UNFAIR_LOCK_INIT;
static LSFGHudSnapshot snap;
static bool haveSnap;
static double powerW = -1;   // the whole Mac, from the battery controller's telemetry (-1: unknown)

// SystemLoad (mW): what the whole system draws, on battery or on the adapter. Portables only.
static double readPowerW(void) {
    static io_service_t battery;
    static bool looked;
    if (!looked) {
        looked = true;
        battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    }
    if (!battery) return -1;
    double watts = -1;
    CFTypeRef telemetry = IORegistryEntryCreateCFProperty(battery, CFSTR("PowerTelemetryData"), kCFAllocatorDefault, 0);
    if (telemetry && CFGetTypeID(telemetry) == CFDictionaryGetTypeID()) {
        CFNumberRef load = (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)telemetry, CFSTR("SystemLoad"));
        long long mw = 0;
        if (load && CFGetTypeID(load) == CFNumberGetTypeID() && CFNumberGetValue(load, kCFNumberLongLongType, &mw) && mw > 0)
            watts = mw / 1000.0;
    }
    if (telemetry) CFRelease(telemetry);
    return watts;
}

extern "C" void lsfgHudPublish(const LSFGHudSnapshot *s) {
    const double w = readPowerW();
    os_unfair_lock_lock(&snapLock);
    snap = *s;
    haveSnap = true;
    powerW = w;
    os_unfair_lock_unlock(&snapLock);
}

extern "C" void lsfgHudScreenFrame(float ms) { screenRing.push(ms); }
extern "C" void lsfgHudGameFrame(float ms) { gameRing.push(ms); }

#pragma mark - Drawing

// Styled after Apple's Metal Performance HUD: a plain dark panel in the top-right corner, one small monospaced
// font, a label and a right-aligned number per line.
static const ImVec4 kText = ImVec4(1.0f, 1.0f, 1.0f, 1.0f);
static const ImVec4 kLabel = ImVec4(1.0f, 1.0f, 1.0f, 0.75f);
static const ImVec4 kDim = ImVec4(1.0f, 1.0f, 1.0f, 0.5f);
static const ImVec4 kGood = ImVec4(0.40f, 0.95f, 0.40f, 1.0f);
static const ImVec4 kWarn = ImVec4(1.00f, 0.85f, 0.25f, 1.0f);
static const ImVec4 kBad = ImVec4(1.00f, 0.35f, 0.30f, 1.0f);
static const float kWidth = 220;   // points

static void setUp(id<MTLDevice> device) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = nullptr;
    io.LogFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NoMouse | ImGuiConfigFlags_NoKeyboard;
    // Menlo, the Mac's plain monospaced font (ImGui's built-in pixel font if it's missing).
    ImFont *font = nullptr;
    if ([NSFileManager.defaultManager fileExistsAtPath:@"/System/Library/Fonts/Menlo.ttc"])
        font = io.Fonts->AddFontFromFileTTF("/System/Library/Fonts/Menlo.ttc");
    if (!font) io.Fonts->AddFontDefault();

    ImGuiStyle &style = ImGui::GetStyle();
    style.FontSizeBase = 11.0f;
    style.WindowRounding = 0.0f;
    style.WindowBorderSize = 0.0f;
    style.WindowPadding = ImVec2(6, 5);
    style.ItemSpacing = ImVec2(0, 1);
    style.Colors[ImGuiCol_WindowBg] = ImVec4(0, 0, 0, 0.6f);
    style.Colors[ImGuiCol_Text] = kText;
    ImGui_ImplMetal_Init(device);
}

#pragma mark Frame cost

// Where one game frame's GPU time goes: the game itself, the DLSS replacement, LSFG, and the overlay's display pass,
// drawn as one bar against the frame's time budget (the game's frame interval). The running totals are sampled
// every 100 ms and averaged over the last 30 seconds, so the bar is steady; the average starts over when a setting
// changes, so it always describes the settings on screen.
enum { kParts = 4, kSamples = 301 };
static const ImVec4 kPartColor[kParts] = {
    ImVec4(0.45f, 0.62f, 1.00f, 1.0f),   // game
    ImVec4(0.80f, 0.50f, 1.00f, 1.0f),   // DLSS replacement
    ImVec4(0.35f, 0.90f, 0.55f, 1.0f),   // LSFG
    ImVec4(1.00f, 0.68f, 0.28f, 1.0f),   // display pass
};
struct Cost { float part[kParts]; float budget; float seconds; };   // ms per game frame, over `seconds`
struct Sample { CFTimeInterval time; LSFGHudTotals totals; };
static Sample samples[kSamples];
static int sampleCount;      // since the last reset
static Cost current;

static void sampleCost(CFTimeInterval now) {
    const Sample *last = sampleCount ? &samples[(sampleCount - 1) % kSamples] : nullptr;
    if (last && now - last->time < 0.1) return;
    LSFGHudTotals t;
    lsfgHudReadTotals(&t);
    if (last && t.settingsChanges != last->totals.settingsChanges) { sampleCount = 0; current = Cost{}; }   // start over
    samples[sampleCount % kSamples] = Sample{now, t};
    sampleCount++;
    if (sampleCount < 6) return;   // half a second before the first numbers
    const Sample &o = samples[sampleCount > kSamples ? sampleCount % kSamples : 0], &n = samples[(sampleCount - 1) % kSamples];
    const LSFGHudTotals &a = o.totals, &b = n.totals;
    const double frames = (double)(b.gameFrames - a.gameFrames);
    if (frames <= 0) return;
    const double lsfgFrames = (double)(b.lsfgFrames - a.lsfgFrames), upFrames = (double)(b.upscaleFrames - a.upscaleFrames);
    const double lsfg = b.lsfgMs - a.lsfgMs, up = b.upscaleMs - a.upscaleMs;
    Cost c = {};
    c.part[0] = (float)fmax(0, (b.gpuBusyMs - a.gpuBusyMs - up - (b.lsfgInGameWork ? lsfg : 0)) / frames);
    c.part[1] = upFrames > 0 ? (float)(up / upFrames) : 0;
    c.part[2] = lsfgFrames > 0 ? (float)(lsfg / lsfgFrames) : 0;
    c.part[3] = (float)((b.displayMs - a.displayMs) / frames);
    c.budget = (float)((n.time - o.time) * 1000 / frames);
    c.seconds = (float)(n.time - o.time);
    current = c;
}

// The bar is the frame's budget; what's left after the parts is time the GPU wasn't working on this frame.
// When the parts take longer than the budget, the bar is scaled to them and a tick marks the budget.
static void costBar(const Cost &c) {
    const float height = 12;
    ImDrawList *dl = ImGui::GetWindowDrawList();
    const ImVec2 p = ImGui::GetCursorScreenPos();
    const float total = c.part[0] + c.part[1] + c.part[2] + c.part[3];
    const float span = fmaxf(fmaxf(c.budget, total), 0.001f);
    dl->AddRectFilled(p, ImVec2(p.x + kWidth, p.y + height), IM_COL32(255, 255, 255, 22));
    float x = p.x;
    for (int k = 0; k < kParts; k++) {
        const float w = c.part[k] / span * kWidth;
        if (w <= 0) continue;
        dl->AddRectFilled(ImVec2(x, p.y), ImVec2(fminf(x + w, p.x + kWidth), p.y + height), ImGui::GetColorU32(kPartColor[k]));
        x += w;
    }
    if (total > c.budget && c.budget > 0) {
        const float bx = p.x + c.budget / span * kWidth;
        dl->AddLine(ImVec2(bx, p.y - 2), ImVec2(bx, p.y + height + 2), IM_COL32(255, 255, 255, 230), 1.5f);
    }
    ImGui::Dummy(ImVec2(kWidth, height + 3));
}

#pragma mark Lines

// One line: label on the left, value right-aligned; with `swatch`, a colored square before the label.
static void line(const ImVec4 *swatch, const char *label, ImVec4 color, const char *fmt, ...) IM_FMTARGS(4);
static void line(const ImVec4 *swatch, const char *label, ImVec4 color, const char *fmt, ...) {
    char text[96];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(text, sizeof text, fmt, ap);
    va_end(ap);
    if (swatch) {
        const ImVec2 p = ImGui::GetCursorScreenPos();
        const float s = ImGui::GetFontSize() * 0.7f, pad = (ImGui::GetFontSize() - s) / 2;
        ImGui::GetWindowDrawList()->AddRectFilled(ImVec2(p.x, p.y + pad), ImVec2(p.x + s, p.y + pad + s), ImGui::GetColorU32(*swatch));
        ImGui::Dummy(ImVec2(s + 4, ImGui::GetFontSize()));
        ImGui::SameLine(0, 0);
    }
    ImGui::TextColored(kLabel, "%s", label);
    ImGui::SameLine(kWidth - ImGui::CalcTextSize(text).x + ImGui::GetStyle().WindowPadding.x);
    ImGui::TextColored(color, "%s", text);
}

// "LSFG 2× performance" -> "LSFG 2× perf"; "LS1 perf 1728×1117 → …" -> "LS1 perf".
static void shortName(char *out, size_t size, const char *name) {
    snprintf(out, size, "%s", name);
    char *perf = strstr(out, "performance"); if (perf) strcpy(perf, "perf");
    char *qual = strstr(out, "quality"); if (qual) strcpy(qual, "qual");
    for (char *c = out; *c; c++) if (*c >= '0' && *c <= '9' && c > out && c[-1] == ' ' && strstr(c, "\xc3\x97") && strstr(c, "\xe2\x86\x92")) { c[-1] = 0; break; }
}

static void drawHUD(void) {
    os_unfair_lock_lock(&snapLock);
    const LSFGHudSnapshot s = snap;
    const bool have = haveSnap;
    const double watts = powerW;
    os_unfair_lock_unlock(&snapLock);

    const ImGuiIO &io = ImGui::GetIO();
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x - 8, 8), ImGuiCond_Always, ImVec2(1, 0));
    ImGui::SetNextWindowSizeConstraints(ImVec2(kWidth + 12, 0), ImVec2(kWidth + 12, FLT_MAX));
    ImGui::Begin("Lightscale", nullptr, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs |
                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoFocusOnAppearing | ImGuiWindowFlags_NoNav);
    if (!have) {
        ImGui::TextColored(kDim, "Lightscale: measuring...");
        ImGui::End();
        return;
    }
    line(nullptr, "FPS", kText, "%d | game %d", s.screenFps, s.gameFps);
    const ImVec4 jitter = s.intervalSdMs < 1 ? kGood : s.intervalSdMs < 3 ? kWarn : kBad;
    if (s.dropped) line(nullptr, "Frame", kBad, "%.2f ms ±%.1f, %d drop", s.intervalMs, s.intervalSdMs, s.dropped);
    else line(nullptr, "Frame", jitter, "%.2f ms ±%.1f", s.intervalMs, s.intervalSdMs);

    // One average game frame, with only the parts that run.
    const Cost &c = current;
    const float total = c.part[0] + c.part[1] + c.part[2] + c.part[3];
    if (c.budget > 0) {
        char span[24];
        snprintf(span, sizeof span, c.seconds < 29.5f ? "avg %.0f s" : "avg 30 s", c.seconds);
        line(nullptr, "Frame cost", kDim, "%s", span);
        costBar(c);
        char name[48];
        line(&kPartColor[0], "Game", kText, "%.2f ms", c.part[0]);
        if (c.part[1] > 0 && s.upscaler[0]) line(&kPartColor[1], s.upscaler, kText, "%.2f ms", c.part[1]);
        if (c.part[2] > 0) { shortName(name, sizeof name, s.frameGen); line(&kPartColor[2], name, kText, "%.2f ms", c.part[2]); }
        if (s.scaling[0]) shortName(name, sizeof name, s.scaling); else snprintf(name, sizeof name, "Overlay");
        if (c.part[3] > 0) line(&kPartColor[3], name, kText, "%.2f ms", c.part[3]);
        line(nullptr, "GPU of budget", total > c.budget * 0.9f ? kWarn : kText, "%.1f / %.1f ms", total, c.budget);
    } else {
        line(nullptr, "Frame cost", kDim, "measuring...");
    }

    line(nullptr, "Latency", kText, "+%.0f ms", s.queuedMs);
    if (watts > 0) line(nullptr, "Power", s.thermal >= 2 ? kBad : kText, s.thermal >= 2 ? "%.1f W throttling" : "%.1f W", watts);
    line(nullptr, "Memory", kText, "%.1f GB", s.memoryMB / 1024);
    if (s.refreshHz > 0 && s.screenFps >= s.refreshHz * 0.93) line(nullptr, "Limit", kGood, "display %.0f Hz", s.refreshHz);
    else if (c.budget > 0 && total > c.budget * 0.9f) line(nullptr, "Limit", kWarn, "GPU");
    else if (s.dropped > 2) line(nullptr, "Limit", kWarn, "pacing");
    else line(nullptr, "Limit", kText, "game/CPU");
    ImGui::End();
}

extern "C" void lsfgHudEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target, float scale) {
    static bool ready;
    static CFTimeInterval last;
    if (!ready) { setUp(cb.device); ready = true; }
    if (!(scale > 0)) scale = 1;
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(target.width / scale, target.height / scale);
    io.DisplayFramebufferScale = ImVec2(scale, scale);
    const CFTimeInterval now = CACurrentMediaTime();
    io.DeltaTime = last > 0 ? (float)fmin(fmax(now - last, 1e-4), 0.1) : 1.0f / 60;
    last = now;
    sampleCost(now);

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui::NewFrame();
    drawHUD();
    ImGui::Render();
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:rp];
    encoder.label = @"Lightscale HUD";
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, encoder);
    [encoder endEncoding];
}
