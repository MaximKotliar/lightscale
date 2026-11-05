// In-game performance HUD (see lsfg_hud.h). Dear ImGui (vendor/imgui, MIT) with its Metal backend; no
// platform backend: the HUD takes no input, so only the display size and the clock are fed in.
#import "lsfg_hud.h"
#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#import <QuartzCore/QuartzCore.h>
#include <atomic>
#include <dlfcn.h>
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
#pragma mark Power

// Read every 250 ms on a background queue while the HUD is drawn:
// - the whole Mac: the SMC's total system power (PSTR, refreshed about once a second), or on Macs without it the
//   battery controller's SystemLoad (every few seconds);
// - the GPU: its energy counter from IOReport (as powermetrics reads it), averaged over the last second.
static os_unfair_lock powerLock = OS_UNFAIR_LOCK_INIT;
static double systemW = -1, gpuW = -1;   // -1: unknown
static std::atomic<double> lastDrawn{0};  // CACurrentMediaTime of the last HUD frame

// SystemLoad (mW): what the whole system draws, on battery or on the adapter. Portables only.
static double readBatteryW(void) {
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

// The SMC's PSTR key (float watts), through AppleSMC's user client: the struct and selector every SMC tool uses.
struct SMCKeyData {
    uint32_t key;
    uint8_t vers[6]; uint8_t pad0[2];
    uint16_t plVersion, plLength; uint32_t cpuPLimit, gpuPLimit, memPLimit;
    uint32_t dataSize, dataType; uint8_t dataAttributes; uint8_t pad1[3];
    uint8_t result, status, data8; uint8_t pad2; uint32_t data32;
    uint8_t bytes[32];
};
static_assert(sizeof(SMCKeyData) == 80, "AppleSMC's struct");
static double readSMCW(void) {
    static io_connect_t smc;
    static bool looked, broken;
    static uint32_t size, type;
    if (broken) return -1;
    if (!looked) {
        looked = true;
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (!service || IOServiceOpen(service, mach_task_self(), 0, &smc) != KERN_SUCCESS) { broken = true; return -1; }
        IOObjectRelease(service);
        SMCKeyData in = {}, out = {};
        size_t n = sizeof out;
        in.key = 'PSTR';
        in.data8 = 9;   // key info
        if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &n) != KERN_SUCCESS || out.result || out.dataType != 'flt ') {
            broken = true;
            return -1;
        }
        size = out.dataSize; type = out.dataType;
    }
    SMCKeyData in = {}, out = {};
    size_t n = sizeof out;
    in.key = 'PSTR';
    in.dataSize = size; in.dataType = type;
    in.data8 = 5;   // read
    if (IOConnectCallStructMethod(smc, 2, &in, sizeof in, &out, &n) != KERN_SUCCESS || out.result) return -1;
    float w;
    memcpy(&w, out.bytes, sizeof w);
    return w > 0 && w < 2000 ? w : -1;
}

// IOReport (private, /usr/lib/libIOReport.dylib, loaded at run time): the "GPU Energy" channel of "Energy Model".
static struct {
    bool tried, ok;
    CFDictionaryRef (*copyGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
    void *(*subscribe)(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
    CFDictionaryRef (*sample)(void *, CFMutableDictionaryRef, CFTypeRef);
    CFDictionaryRef (*delta)(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
    int64_t (*integer)(CFDictionaryRef, int32_t);
    CFStringRef (*name)(CFDictionaryRef), (*unit)(CFDictionaryRef);
    void *subscription;
    CFMutableDictionaryRef channels;
    CFDictionaryRef previous;
    CFTimeInterval previousTime;
    double joules[4], seconds[4];   // the last four intervals: about a second
    int next;
} ior;

static bool setUpIOReport(void) {
    if (ior.tried) return ior.ok;
    ior.tried = true;
    void *lib = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!lib) return false;
    ior.copyGroup = (decltype(ior.copyGroup))dlsym(lib, "IOReportCopyChannelsInGroup");
    ior.subscribe = (decltype(ior.subscribe))dlsym(lib, "IOReportCreateSubscription");
    ior.sample = (decltype(ior.sample))dlsym(lib, "IOReportCreateSamples");
    ior.delta = (decltype(ior.delta))dlsym(lib, "IOReportCreateSamplesDelta");
    ior.integer = (decltype(ior.integer))dlsym(lib, "IOReportSimpleGetIntegerValue");
    ior.name = (decltype(ior.name))dlsym(lib, "IOReportChannelGetChannelName");
    ior.unit = (decltype(ior.unit))dlsym(lib, "IOReportChannelGetUnitLabel");
    if (!ior.copyGroup || !ior.subscribe || !ior.sample || !ior.delta || !ior.integer || !ior.name || !ior.unit) return false;
    CFDictionaryRef group = ior.copyGroup(CFSTR("Energy Model"), nullptr, 0, 0, 0);
    if (!group) return false;
    ior.channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, group);
    CFRelease(group);
    CFMutableDictionaryRef subscribed = nullptr;
    ior.subscription = ior.subscribe(nullptr, ior.channels, &subscribed, 0, nullptr);
    if (subscribed) CFRelease(subscribed);
    ior.ok = ior.subscription != nullptr;
    return ior.ok;
}

static double readGPUW(void) {
    if (!setUpIOReport()) return -1;
    CFDictionaryRef now = ior.sample(ior.subscription, ior.channels, nullptr);
    const CFTimeInterval t = CACurrentMediaTime();
    if (!now) return -1;
    double result = -1;
    if (ior.previous && t - ior.previousTime < 2) {
        CFDictionaryRef d = ior.delta(ior.previous, now, nullptr);
        double joules = 0;
        bool found = false;
        CFArrayRef items = d ? (CFArrayRef)CFDictionaryGetValue(d, CFSTR("IOReportChannels")) : nullptr;
        for (CFIndex i = 0, n = items ? CFArrayGetCount(items) : 0; i < n; i++) {
            CFDictionaryRef c = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
            CFStringRef name = ior.name(c);
            if (!name || CFStringCompare(name, CFSTR("GPU Energy"), 0) != kCFCompareEqualTo) continue;
            CFStringRef unit = ior.unit(c);
            const double scale = !unit ? 0 : CFStringCompare(unit, CFSTR("nJ"), 0) == kCFCompareEqualTo ? 1e-9
                               : CFStringCompare(unit, CFSTR("uJ"), 0) == kCFCompareEqualTo ? 1e-6
                               : CFStringCompare(unit, CFSTR("mJ"), 0) == kCFCompareEqualTo ? 1e-3 : 0;
            joules += (double)ior.integer(c, 0) * scale;
            found = scale > 0;
        }
        if (d) CFRelease(d);
        if (found) {
            ior.joules[ior.next % 4] = joules;
            ior.seconds[ior.next % 4] = t - ior.previousTime;
            ior.next++;
            double j = 0, s = 0;
            for (int i = 0; i < 4 && i < ior.next; i++) { j += ior.joules[i]; s += ior.seconds[i]; }
            if (s > 0) result = j / s;
        }
    } else {
        ior.next = 0;   // first sample, or after a pause: start the average over
    }
    if (ior.previous) CFRelease(ior.previous);
    ior.previous = now;
    ior.previousTime = t;
    return result;
}

static void startPowerSampling(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t queue = dispatch_queue_create("lightscale.hud.power", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), 250 * NSEC_PER_MSEC, 25 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            if (CACurrentMediaTime() - lastDrawn.load() > 2) return;   // HUD off: no reads
            double system = readSMCW();
            if (system < 0) system = readBatteryW();
            const double gpu = readGPUW();
            os_unfair_lock_lock(&powerLock);
            systemW = system;
            gpuW = gpu;
            os_unfair_lock_unlock(&powerLock);
        });
        dispatch_resume(timer);
        static dispatch_source_t keep;   // lives as long as the process
        keep = timer;
    });
}

extern "C" void lsfgHudPublish(const LSFGHudSnapshot *s) {
    os_unfair_lock_lock(&snapLock);
    snap = *s;
    haveSnap = true;
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
// every 100 ms and averaged over the last 2 seconds, so the bar is steady; the average starts over when a setting
// changes, so it always describes the settings on screen.
enum { kParts = 4, kSamples = 21 };   // 2 s of 100 ms samples
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
    // the overlay: one pass on its own (a low percentile) times the passes per game frame, since the mean also
    // counts the game's work that ran in between
    c.part[3] = (float)(b.displayPassMs > 0 ? b.displayPassMs * (double)(b.displayPasses - a.displayPasses) / frames
                                             : (b.displayMs - a.displayMs) / frames);
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
    os_unfair_lock_unlock(&snapLock);
    os_unfair_lock_lock(&powerLock);
    const double watts = systemW, gpuWatts = gpuW;
    os_unfair_lock_unlock(&powerLock);

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
        snprintf(span, sizeof span, c.seconds < 1.95f ? "avg %.1f s" : "avg 2 s", c.seconds);
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
    if (gpuWatts >= 0) line(nullptr, "GPU power", kText, "%.1f W", gpuWatts);
    line(nullptr, "Memory", kText, "%.1f GB", s.memoryMB / 1024);
    if (s.refreshHz > 0 && s.screenFps >= s.refreshHz * 0.93) line(nullptr, "Limit", kGood, "display %.0f Hz", s.refreshHz);
    else if (c.budget > 0 && total > c.budget * 0.9f) line(nullptr, "Limit", kWarn, "GPU");
    else if (s.dropped > 2) line(nullptr, "Limit", kWarn, "pacing");
    else line(nullptr, "Limit", kText, "game/CPU");
    ImGui::End();
}

// --- Colour: the HUD's colours are sRGB; in an HDR target they're converted per vertex after ImGui lays it out.
// Blending then happens in the target's encoding, which only shifts the panel's translucency a little.
enum ColorMode { kColorSDR, kColorPQ2020, kColorLinearSRGB, kColorLinear2020 };
static std::atomic<int> colorMode{kColorSDR};
// In PQ the HUD is drawn vivid rather than exact: its colours taken as Display P3 (wider than sRGB, as macOS's own
// vivid UI) and white a bit above BT.2408's 203-nit SDR white, so it holds its own next to the game's HDR.
static const float kHudWhiteNits = 300;

extern "C" const char *lsfgHudSetColorSpace(CGColorSpaceRef space) {
    CFStringRef name = space ? CGColorSpaceCopyName(space) : NULL;
    int mode = kColorSDR;
    const char *label = space ? "SDR" : "none (SDR)";
    if (name) {
        if (CFEqual(name, kCGColorSpaceITUR_2100_PQ)    // and the older names (deprecated constants)
            || CFEqual(name, CFSTR("kCGColorSpaceITUR_2020_PQ")) || CFEqual(name, CFSTR("kCGColorSpaceITUR_2020_PQ_EOTF"))) { mode = kColorPQ2020; label = "HDR10 (PQ, BT.2020)"; }
        else if (CFEqual(name, kCGColorSpaceExtendedLinearSRGB) || CFEqual(name, kCGColorSpaceLinearSRGB)) {
            mode = kColorLinearSRGB; label = "linear sRGB"; }
        else if (CFEqual(name, kCGColorSpaceExtendedLinearITUR_2020) || CFEqual(name, kCGColorSpaceLinearITUR_2020)) {
            mode = kColorLinear2020; label = "linear BT.2020"; }
        CFRelease(name);
    }
    colorMode.store(mode);
    return label;
}

static float srgbToLinear(float c) { return c <= 0.04045f ? c / 12.92f : powf((c + 0.055f) / 1.055f, 2.4f); }

static float linearToPQ(float nits) {   // SMPTE ST 2084
    const float m1 = 0.1593017578125f, m2 = 78.84375f, c1 = 0.8359375f, c2 = 18.8515625f, c3 = 18.6875f;
    const float y = powf(fmaxf(nits, 0) / 10000, m1);
    return powf((c1 + c2 * y) / (1 + c3 * y), m2);
}

// One 8-bit sRGB channel triple to the target's encoding (a table per mode would do too; vertices are few).
static ImU32 convertColor(ImU32 c, int mode) {
    float r = srgbToLinear(((c >> IM_COL32_R_SHIFT) & 0xFF) / 255.0f);
    float g = srgbToLinear(((c >> IM_COL32_G_SHIFT) & 0xFF) / 255.0f);
    float b = srgbToLinear(((c >> IM_COL32_B_SHIFT) & 0xFF) / 255.0f);
    if (mode == kColorPQ2020) {   // Display P3 -> BT.2020 primaries
        const float r2 = 0.7539f * r + 0.1986f * g + 0.0476f * b;
        const float g2 = 0.0457f * r + 0.9418f * g + 0.0125f * b;
        const float b2 = -0.0012f * r + 0.0176f * g + 0.9836f * b;
        r = r2; g = g2; b = b2;
    } else if (mode == kColorLinear2020) {   // BT.709 -> BT.2020 primaries (BT.2087)
        const float r2 = 0.6274f * r + 0.3293f * g + 0.0433f * b;
        const float g2 = 0.0691f * r + 0.9195f * g + 0.0114f * b;
        const float b2 = 0.0164f * r + 0.0880f * g + 0.8956f * b;
        r = r2; g = g2; b = b2;
    }
    if (mode == kColorPQ2020) {
        r = linearToPQ(r * kHudWhiteNits); g = linearToPQ(g * kHudWhiteNits); b = linearToPQ(b * kHudWhiteNits);
    }
    auto byte = [](float v) { return (ImU32)lroundf(fminf(fmaxf(v, 0), 1) * 255); };
    return (byte(r) << IM_COL32_R_SHIFT) | (byte(g) << IM_COL32_G_SHIFT) | (byte(b) << IM_COL32_B_SHIFT)
         | (c & ((ImU32)0xFF << IM_COL32_A_SHIFT));
}

static void convertColors(ImDrawData *data) {
    const int mode = colorMode.load();
    if (mode == kColorSDR) return;
    for (ImDrawList *list : data->CmdLists)
        for (ImDrawVert &v : list->VtxBuffer) v.col = convertColor(v.col, mode);
}

// The app icon as an outline, `size` points square at `p` (824-unit grid, y down, after scripts/make-icon.swift):
// the rounded square; two frames offset diagonally ("the frame in between"), the front one bigger, centred
// together; a sparkle in the front one. One line weight; the back frame stops half a line width short of the front one where it would pass behind.
static void drawIconOutline(ImDrawList *dl, ImVec2 p, float size, float alpha, ImVec4 color) {
    const float k = size / 824, line = size * 0.04f;   // 1.6 pt at 40 pt
    const float L = line / k;                          // line width in grid units
    auto at = [&](float x, float y) { return ImVec2(p.x + x * k, p.y + y * k); };
    const ImU32 white = ImGui::ColorConvertFloat4ToU32(ImVec4(color.x, color.y, color.z, alpha));
    dl->AddRect(at(0, 0), at(824, 824), white, 185 * k, 0, line);

    // Frames: a small one behind, a bigger one in front, 130 right of and 130 above its bottom-left corner (so the
    // back one shows the same amount at its top and right); together centred.
    const float bw = 360, bh = 260, fw = 440, fh = 316, d = 130, r = 48;
    const float groupW = d + fw, groupH = bh + fh - d;
    const float bx = 412 - groupW / 2, fy = 412 - groupH / 2;   // back frame's left, front frame's top
    const float fx = bx + d, by = fy + fh + d - bh;               // front frame's left, back frame's top
    dl->AddRect(at(fx, fy), at(fx + fw, fy + fh), white, r * k, 0, line);
    // Back frame: from its top edge (stopping short of the front frame's left edge) round the left and bottom to its
    // right edge (stopping short of the front frame's bottom edge). Butt ends, so the gap is measured from them.
    const float stop = L / 2 + L / 2;   // front line's half width + a gap of half a line width
    dl->PathLineTo(at(fx - stop, by));
    dl->PathArcTo(at(bx + r, by + r), r * k, -(float)M_PI / 2, -(float)M_PI);
    dl->PathArcTo(at(bx + r, by + bh - r), r * k, (float)M_PI, (float)M_PI / 2);
    dl->PathArcTo(at(bx + bw - r, by + bh - r), r * k, (float)M_PI / 2, 0);
    dl->PathLineTo(at(bx + bw, fy + fh + stop));
    dl->PathStroke(white, 0, line);

    // Sparkle, centred in the front frame: four points joined by inward curves.
    const ImVec2 c = at(fx + fw / 2, fy + fh / 2);
    const float sr = 100 * k, in = sr * 0.18f;
    dl->PathLineTo(ImVec2(c.x, c.y - sr));
    dl->PathBezierQuadraticCurveTo(ImVec2(c.x + in, c.y - in), ImVec2(c.x + sr, c.y));
    dl->PathBezierQuadraticCurveTo(ImVec2(c.x + in, c.y + in), ImVec2(c.x, c.y + sr));
    dl->PathBezierQuadraticCurveTo(ImVec2(c.x - in, c.y + in), ImVec2(c.x - sr, c.y));
    dl->PathBezierQuadraticCurveTo(ImVec2(c.x - in, c.y - in), ImVec2(c.x, c.y - sr));
    dl->PathFillConcave(white);
}

// The badge: for the first seconds of the game, the app icon's outline in the bottom-left corner, so players see
// it's working. `size`: its side in the HUD's points.
static void drawBadge(float alpha, float size) {
    alpha = fminf(fmaxf(alpha, 0), 1);
    const ImGuiIO &io = ImGui::GetIO();
    const float margin = size * 0.3f;
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    const ImVec2 p(margin, io.DisplaySize.y - margin - size);
    drawIconOutline(dl, p, size, alpha, ImVec4(1, 1, 1, 1));
}

extern "C" void lsfgHudEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target, float scale, bool stats, float badgeAlpha,
                              float badgePoints) {
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
    if (stats) {
        lastDrawn.store(now);
        startPowerSampling();
        sampleCost(now);
    }

    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui::NewFrame();
    if (stats) drawHUD();
    if (badgeAlpha > 0) drawBadge(badgeAlpha, badgePoints);
    ImGui::Render();
    convertColors(ImGui::GetDrawData());
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:rp];
    encoder.label = @"Lightscale HUD";
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, encoder);
    [encoder endEncoding];
}
