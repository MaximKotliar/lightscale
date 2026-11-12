// Native (macOS) side of the CrossOver hook.
//
// Wine dlopen()s this library when lsfghook.dll (the PE side) asks for its Unix
// functions, so this code runs inside the game process, next to D3DMetal.
//
// How frames are inserted (D3DMetal, seen in Witcher 3): each real frame is drawn into a
// drawable by one render pass, its command buffer is committed, then -present is called.
// In the commit hook we append to that same command buffer: copy the drawable into LSFG,
// run LSFG, copy the generated frame into a second drawable. In the present hook we show
// the generated drawable, then the real one, each half a real-frame interval apart.
//
// Settings come from the game's profile in ~/Library/Application Support/Lightscale/profiles.json
// (written by the app): {"default": {...}, "games": {"witcher3.exe": {...}}} with keys
// enabled, performance, flowScale, bufferMs. Environment variables override them:
//   LSFG_ENABLE=0        load but install no hooks
//   LSFG_FG=0            observe only, no frame generation (default: on)
//   LSFG_FLOW_SCALE=F    motion-estimation resolution, 0.25-1.0 (default 1.0)
//   LSFG_PERFORMANCE=0   use LSFG quality mode (default: performance mode)
//   LSFG_READABLE=0      leave framebufferOnly alone (disables frame generation)
//   LSFG_MULTIPLIER=N    2 (default), 3 or 4 frames shown per real frame
//   LSFG_BUFFER_MS=N     scheduling headroom that absorbs frame-time jitter (default 8 ms)
//   LSFG_LOG=path        log file (default ~/Library/Logs/Lightscale.log)

// Metal 4 code (MTL4CommandQueue etc.) only runs when a game submits through Metal 4, which
// itself needs macOS 26, so the availability warnings for it don't apply.
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import <AppKit/AppKit.h>
#import "lsfg_hud.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_time.h>
#import <sys/stat.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <math.h>
#import <stdatomic.h>

#pragma mark - Paths

// The app's data folder (working name "Lightscale"); before the rename it was lsfg-metal. The app moves it and
// leaves a link at the old path, but a hook installed by hand may still only have the old folder.
static NSString *appDataDir(void) {
    NSString *base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    NSString *now = [base stringByAppendingPathComponent:@"Lightscale"];
    if ([NSFileManager.defaultManager fileExistsAtPath:now]) return now;
    return [base stringByAppendingPathComponent:@"lsfg-metal"];
}

#pragma mark - Logging

static void lsfg_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void lsfg_log(NSString *fmt, ...) {
    static dispatch_once_t once;
    static FILE *file;
    dispatch_once(&once, ^{
        const char *path = getenv("LSFG_LOG");
        NSString *p = path ? @(path) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Lightscale.log"];
        file = fopen(p.fileSystemRepresentation, "a");
    });
    if (!file) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(file, "[%.3f pid %d] %s\n", CACurrentMediaTime(), getpid(), msg.UTF8String);
    fflush(file);
}

#pragma mark - Counters

typedef enum {
    kDrawablePresent, kDrawablePresentAtTime, kDrawablePresentAfter,
    kCBPresent, kCBPresentAtTime, kCBPresentAfter,
    kMTL4Signal, kMTL4Wait, kNextDrawable, kGenerated, kLinkUpdates, kSkipped, kMTL4Commit, kLateBatches, kCaptured, kCounterCount
} Counter;
static const char *counterNames[kCounterCount] = {
    "drawable.present", "drawable.presentAtTime", "drawable.presentAfterMinimumDuration",
    "cmdbuf.presentDrawable", "cmdbuf.presentDrawable:atTime", "cmdbuf.presentDrawable:afterMinimumDuration",
    "mtl4queue.signalDrawable", "mtl4queue.waitForDrawable", "layer.nextDrawable", "generated", "link.updates", "frames.skipped", "mtl4queue.commit", "batches.late", "frames.captured",
};
static _Atomic long counters[kCounterCount];
static _Atomic bool describedLayer;

static void bump(Counter c) { atomic_fetch_add(&counters[c], 1); }

static void describeDrawable(id<CAMetalDrawable> d, const char *via) {
    if (atomic_exchange(&describedLayer, true)) return;
    CAMetalLayer *l = d.layer;
    id<MTLTexture> t = d.texture;
    lsfg_log(@"first present via %s: drawable %@ texture %lux%lu fmt %lu usage 0x%lx | layer %@ size %.0fx%.0f "
             @"framebufferOnly %d maxDrawables %lu displaySync %d device %@",
             via, NSStringFromClass([(id)d class]), (unsigned long)t.width, (unsigned long)t.height,
             (unsigned long)t.pixelFormat, (unsigned long)t.usage, NSStringFromClass([l class]),
             l.drawableSize.width, l.drawableSize.height, l.framebufferOnly, (unsigned long)l.maximumDrawableCount,
             l.displaySyncEnabled, l.device.name);
}

#pragma mark - Swizzling

// Matching must never message a class or resolve a selector on it: that can run the
// class's +initialize, and arbitrary classes may throw or block there (seen in Witcher 3:
// an exception from +initialize hung D3DMetal's present queue). Only read the runtime's
// tables: protocol lists here, method lists in hookAll.
static BOOL conforms(Class c, Protocol *p) {
    for (; c; c = class_getSuperclass(c))
        if (class_conformsToProtocol(c, p)) return YES;
    return NO;
}

static os_unfair_lock hookLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *hooked;

// For every class matching `match` that itself implements `sel`, replaces the method with
// `make(original)`. Each class gets its own block capturing its own original IMP, so
// subclasses that call super chain correctly.
// One class list per scan (installPresentHooks sets it); copying it is the slow part.
static Class *scanClasses;
static unsigned scanCount;

static void hookAll(SEL sel, BOOL (^match)(Class), id (^make)(IMP original)) {
    os_unfair_lock_lock(&hookLock);
    if (!hooked) hooked = [NSMutableSet set];
    unsigned count = scanCount;
    Class *classes = scanClasses;
    BOOL ownList = classes == NULL;
    if (ownList) classes = objc_copyClassList(&count);
    for (unsigned i = 0; i < count; i++) {
        Class c = classes[i];
        NSString *key = [NSString stringWithFormat:@"%s|%s", class_getName(c), sel_getName(sel)];
        if ([hooked containsObject:key] || !match(c)) continue;
        unsigned n = 0;
        Method *methods = class_copyMethodList(c, &n);
        Method m = NULL;
        for (unsigned k = 0; k < n; k++) if (method_getName(methods[k]) == sel) { m = methods[k]; break; }
        free(methods);
        if (!m) continue;
        IMP old = method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(make(old)));
        [hooked addObject:key];
        lsfg_log(@"hooked -[%s %s]", class_getName(c), sel_getName(sel));
    }
    if (ownList) free(classes);
    os_unfair_lock_unlock(&hookLock);
}

#pragma mark - Frame-path diagnostics

// Detailed logging for the first frames only: which pass writes the drawable, from which
// texture, and whether its command buffer is committed before or after -present.
static const int kDiagFrames = 6;
static _Atomic int diagPresents = 1000;  // set to 0 once every hook is installed
static __weak id lastDrawableCB;          // most recent command buffer that wrote a drawable
static void *drawableTextures[8];  // recent drawable textures, compared by pointer only
static _Atomic unsigned drawableIndex;
static char kWritesDrawableKey, kOwnerKey;

// Marks the command buffer that owns `encoder` (if known) as writing a drawable.
static void markOwnerWritesDrawable(id encoder) {
    id cb = objc_getAssociatedObject(encoder, &kOwnerKey);
    if (!cb) return;
    objc_setAssociatedObject(cb, &kWritesDrawableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    lastDrawableCB = cb;
}

static BOOL diagActive(void) { return atomic_load(&diagPresents) < kDiagFrames; }
static BOOL isDrawableTexture(id t) {
    if (!t) return NO;
    for (int i = 0; i < 8; i++) if (drawableTextures[i] == (__bridge void *)t) return YES;
    return NO;
}
static NSString *describeTexture(id<MTLTexture> t) {
    return t ? [NSString stringWithFormat:@"%@ %p %lux%lu fmt %lu usage 0x%lx storage %lu", NSStringFromClass([(id)t class]),
                (__bridge void *)t, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat,
                (unsigned long)t.usage, (unsigned long)t.storageMode] : @"nil";
}
static NSString *threadName(void) {
    char name[64] = {0};
    pthread_getname_np(pthread_self(), name, sizeof name);
    return [NSString stringWithFormat:@"%s/%p", name[0] ? name : "?", (void *)pthread_self()];
}

#pragma mark - Frame generation

typedef void *(*bridge_create_fn)(const void *, int, int, unsigned, int, float, int, char *, int);
typedef const void *(*bridge_texture_fn)(void *);
typedef int (*bridge_encode_fn)(void *, const void *);
typedef const void *(*bridge_output_fn)(void *, int);
typedef void (*bridge_destroy_fn)(void *);
static struct {
    bridge_create_fn create;
    bridge_texture_fn input;
    bridge_encode_fn encode;
    bridge_output_fn output;
    bridge_destroy_fn destroy;
} bridge;

static BOOL fgAvailable;               // the bridge loaded and drawables are readable
static _Atomic bool fgOn;              // the profile's on/off switch (changes live)
static _Atomic int fgState;            // 0 idle, 1 creating, 2 ready, -1 failed
static void *fgContext;                // used on the game's commit path only
// LSFG couldn't start (no Lossless Scaling, or its kernels aren't built): the overlay still works (HUD, display
// scaling), with frame generation off for good.
static BOOL lsfgMissing;
static void *_Atomic fgPending;        // rebuilt context waiting to replace fgContext
static int fgWarmup;                   // frames to feed LSFG without showing (fresh history)
static __weak id<MTLDevice> fgDevice;
static _Atomic bool overlayHidden;
static NSUInteger fgWidth, fgHeight;
static MTLPixelFormat fgFormat;
static __weak CAMetalLayer *fgLayer;   // layer the game's drawables come from
static char kDrawableTargetKey;        // command buffer -> drawable texture it renders into
static CFTimeInterval lastCompletion, frameInterval;      // GPU completion cadence of real frames

// Our own presentation layer, a sublayer on top of the game's layer.
//
// The game's drawables are never shown: each real frame is copied into a ring texture, and
// generated + real frames are shown on this overlay from our own queue. That way the game
// gets its drawables back immediately (it never waits for the display), and pacing is ours.
// With only the game's 3 drawables, holding generated and real frames until the compositor
// showed them (~25 ms after the GPU finished) made the game wait in nextDrawable.
static CAMetalLayer *overlay;
static _Atomic int overlayState;          // 0 none, 1 attaching, 2 ready, -1 off
// Per-second timing (microseconds), logged as a "timing:" line.
// Total GPU busy time of the game's command buffers (overlapping spans counted once).
static os_unfair_lock busyLock = OS_UNFAIR_LOCK_INIT;
static double busyEnd, busySeconds, busyTotal;   // busyTotal: since the start, for the HUD
static void addGpuSpan(CFTimeInterval start, CFTimeInterval end) {
    if (end <= start) return;
    os_unfair_lock_lock(&busyLock);
    if (end > busyEnd) { busySeconds += end - MAX(start, busyEnd); busyTotal += end - MAX(start, busyEnd); busyEnd = end; }
    os_unfair_lock_unlock(&busyLock);
}
static _Atomic long slotWaitUs, frameGpuUs, frameGpuCount, linkGpuUs, linkGpuCount, queueAheadUs, queueAheadCount;
// Running totals for the HUD's frame-cost graph (nanoseconds), never reset.
static _Atomic long totalSettingsChanges;
static _Atomic long totalGameFrames, totalLsfgNs, totalLsfgFrames, totalUpscaleNs, totalUpscaleFrames, totalDisplayNs, totalDisplayPasses;
// The overlay pass's recent timed durations (ns) and the settings they ran with, for the HUD's low percentile.
enum { kDisplayPassRing = 256 };
static _Atomic long displayPassNs[kDisplayPassRing], displayPassSettings[kDisplayPassRing];
static _Atomic unsigned displayPassNext;
void lsfgHudReadTotals(LSFGHudTotals *t);

// A slot is taken when the game submits a frame and freed once that frame has been shown, which
// can be ~100 ms later (games submit 2-3 frames ahead of the GPU, then LSFG, queueing, display).
enum { kSlots = 6 };
enum { kMaxGenerated = 3 };             // 4x: three frames between each pair of real frames
static id<MTLTexture> realRing[kSlots], genRing[kSlots][kMaxGenerated];
static dispatch_semaphore_t slotsFree;
static int nextSlot;
static id<MTLCommandQueue> presentQueue;
static dispatch_queue_t presenter;
static NSMutableSet<NSNumber *> *captured; // game drawable textures whose frame we took over
static os_unfair_lock capturedLock = OS_UNFAIR_LOCK_INIT;

// Pacing as the display saw it: intervals between consecutive on-screen frames.
static os_unfair_lock pacingLock = OS_UNFAIR_LOCK_INIT;
static CFTimeInterval lastShown;
static int shownCount, droppedCount;
static double shownSum, shownSumSq, shownMax;

static void trackPresented(id<CAMetalDrawable> d) {
    [d addPresentedHandler:^(id<MTLDrawable> drawable) {
        CFTimeInterval t = drawable.presentedTime;
        os_unfair_lock_lock(&pacingLock);
        if (t == 0) droppedCount++;
        else {
            if (lastShown > 0 && t > lastShown && t - lastShown < 0.25) {
                double dt = (t - lastShown) * 1000;
                shownCount++; shownSum += dt; shownSumSq += dt * dt; shownMax = MAX(shownMax, dt);
                lsfgHudScreenFrame((float)dt);
            }
            lastShown = t;
        }
        os_unfair_lock_unlock(&pacingLock);
    }];
}

// The effective settings for this game: defaults, then profiles.json, then environment.
// upscaler: 0 MetalFX (as the game asked), 1 NSS in its place. nssQuality: 0 low, 1 mid, 2 high, 3 fast (NSSQuality's values).
// scaler (spatial upscalers, lss-metal): 0 off, 1 LS1, 2 FSR, 3 BCAS, 4 bicubic, 5 nearest, 6 NIS (NIS and nearest
// need no Lossless Scaling);
// the overlay then shows the game's frames scaled to the window. scalerSharpness 0-1, scalerPerformance: LS1's
// single-pass variant. hudScale: the HUD's size, 1 = Metal HUD-like.
// fpsCap: the game's frame rate limit (frameCapWait): 0 off, -1 auto (the display's refresh rate divided by the frames
// shown per real frame), otherwise frames per second.
static struct { BOOL enabled, performance; int multiplier; float flowScale, bufferMs; int upscaler, nssQuality;
                int scaler; float scalerSharpness; BOOL scalerPerformance; BOOL hud; float hudScale; int fpsCap; } config = { YES, YES, 2, 1.0f, 8.0f, 0, 1, 0, 0.5f, NO, NO, 1.0f, 0 };
static int scalerMode(NSString *s) {
    NSArray *names = @[@"off", @"ls1", @"fsr", @"bcas", @"bicubic", @"nearest", @"nis"];
    NSUInteger i = [names indexOfObject:s.lowercaseString];
    return i == NSNotFound ? 0 : (int)i;
}

// Settings a capture plan runs (lsfg_capture.m), on top of the profile; nil otherwise.
static NSDictionary *configOverride;

static void applyProfile(NSDictionary *p) {
    if (![p isKindOfClass:NSDictionary.class]) return;
    if ([p[@"enabled"] isKindOfClass:NSNumber.class]) config.enabled = [p[@"enabled"] boolValue];
    if ([p[@"performance"] isKindOfClass:NSNumber.class]) config.performance = [p[@"performance"] boolValue];
    if ([p[@"flowScale"] isKindOfClass:NSNumber.class]) config.flowScale = [p[@"flowScale"] floatValue];
    if ([p[@"bufferMs"] isKindOfClass:NSNumber.class]) config.bufferMs = [p[@"bufferMs"] floatValue];
    if ([p[@"multiplier"] isKindOfClass:NSNumber.class]) config.multiplier = [p[@"multiplier"] intValue];
    if ([p[@"upscaler"] isKindOfClass:NSString.class]) config.upscaler = [p[@"upscaler"] isEqualToString:@"nss"] ? 1 : 0;
    if ([p[@"nssQuality"] isKindOfClass:NSString.class]) {
        NSString *q = p[@"nssQuality"];
        config.nssQuality = [q isEqualToString:@"low"] ? 0 : [q isEqualToString:@"high"] ? 2 : [q isEqualToString:@"fast"] ? 3 : 1;
    }
    if ([p[@"scaler"] isKindOfClass:NSString.class]) config.scaler = scalerMode(p[@"scaler"]);
    if ([p[@"scalerSharpness"] isKindOfClass:NSNumber.class]) config.scalerSharpness = [p[@"scalerSharpness"] floatValue];
    if ([p[@"scalerPerformance"] isKindOfClass:NSNumber.class]) config.scalerPerformance = [p[@"scalerPerformance"] boolValue];
    if ([p[@"hud"] isKindOfClass:NSNumber.class]) config.hud = [p[@"hud"] boolValue];
    if ([p[@"hudScale"] isKindOfClass:NSNumber.class]) config.hudScale = [p[@"hudScale"] floatValue];
    if ([p[@"fpsCap"] isKindOfClass:NSNumber.class]) config.fpsCap = [p[@"fpsCap"] intValue];
}

// The running .exe as a Unix path, sent by the PE side when it loads (nil until then).
static NSString *exePath;

static NSString *profilesPath(void) {
    return [appDataDir() stringByAppendingPathComponent:@"profiles.json"];
}

// The game folder's own settings: .lsfg/profile.json next to the .exe or up to 3 folders above it
// (the app puts it next to the proxy DLL, so launchers and helper .exes in subfolders share it).
static NSString *gameProfilePath(void) {
    NSString *dir = exePath.stringByDeletingLastPathComponent;
    for (int level = 0; dir.length > 1 && level <= 3; level++, dir = dir.stringByDeletingLastPathComponent) {
        NSString *candidate = [dir stringByAppendingPathComponent:@".lsfg/profile.json"];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

static void loadConfig(void) {
    config.enabled = YES; config.performance = YES; config.multiplier = 2;
    config.flowScale = 1.0f; config.bufferMs = 8.0f; config.upscaler = 0; config.nssQuality = 1;
    config.scaler = 0; config.scalerSharpness = 0.5f; config.scalerPerformance = NO; config.hud = NO; config.hudScale = 1.0f;
    config.fpsCap = 0;
    NSData *data = [NSData dataWithContentsOfFile:profilesPath()];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *exe = (exePath.lastPathComponent ?: NSProcessInfo.processInfo.processName).lowercaseString;
    if ([root isKindOfClass:NSDictionary.class]) {
        applyProfile(root[@"default"]);
        NSDictionary *games = root[@"games"];
        if ([games isKindOfClass:NSDictionary.class]) applyProfile(games[exe]);
    }
    NSString *gamePath = gameProfilePath();
    NSData *gameData = gamePath ? [NSData dataWithContentsOfFile:gamePath] : nil;
    if (gameData) applyProfile([NSJSONSerialization JSONObjectWithData:gameData options:0 error:nil]);
    if (configOverride) applyProfile(configOverride);
    // Environment variables (e.g. in the bottle's cxbottle.conf) win over profiles.json, so say so:
    // they also pin those settings against live changes from the app.
    static dispatch_once_t warned;
    dispatch_once(&warned, ^{
        NSMutableArray *set = [NSMutableArray array];
        for (NSString *name in @[@"LSFG_FG", @"LSFG_PERFORMANCE", @"LSFG_FLOW_SCALE", @"LSFG_BUFFER_MS", @"LSFG_MULTIPLIER", @"LSFG_UPSCALER", @"LSFG_NSS_QUALITY", @"LSFG_SCALER", @"LSFG_SCALER_SHARPNESS", @"LSFG_HUD", @"LSFG_HUD_SCALE", @"LSFG_FPS_CAP"])
            if (getenv(name.UTF8String)) [set addObject:name];
        if (set.count) lsfg_log(@"environment overrides the profile (the app can't change these): %@", [set componentsJoinedByString:@", "]);
    });
    const char *v;
    if ((v = getenv("LSFG_FG"))) config.enabled = v[0] != '0';
    if ((v = getenv("LSFG_PERFORMANCE"))) config.performance = v[0] != '0';
    if ((v = getenv("LSFG_FLOW_SCALE"))) config.flowScale = (float)atof(v);
    if ((v = getenv("LSFG_BUFFER_MS"))) config.bufferMs = (float)atof(v);
    if ((v = getenv("LSFG_MULTIPLIER"))) config.multiplier = atoi(v);
    if ((v = getenv("LSFG_UPSCALER"))) config.upscaler = strcmp(v, "nss") == 0 ? 1 : 0;
    if ((v = getenv("LSFG_NSS_QUALITY"))) config.nssQuality = strcmp(v, "low") == 0 ? 0 : strcmp(v, "high") == 0 ? 2 : strcmp(v, "fast") == 0 ? 3 : 1;
    if ((v = getenv("LSFG_SCALER"))) config.scaler = scalerMode(@(v));
    if ((v = getenv("LSFG_SCALER_SHARPNESS"))) config.scalerSharpness = (float)atof(v);
    if ((v = getenv("LSFG_HUD"))) config.hud = v[0] != '0';
    if ((v = getenv("LSFG_HUD_SCALE"))) config.hudScale = (float)atof(v);
    if ((v = getenv("LSFG_FPS_CAP"))) config.fpsCap = strcmp(v, "auto") == 0 ? -1 : atoi(v);
    config.fpsCap = config.fpsCap < 0 ? -1 : config.fpsCap == 0 ? 0 : MAX(10, MIN(config.fpsCap, 500));
    config.hudScale = isfinite(config.hudScale) ? fminf(fmaxf(config.hudScale, 0.5f), 3.0f) : 1.0f;
    config.scalerSharpness = fminf(fmaxf(config.scalerSharpness, 0.0f), 1.0f);
    config.multiplier = MAX(2, MIN(config.multiplier, kMaxGenerated + 1));
    config.flowScale = fminf(fmaxf(config.flowScale, 0.25f), 1.0f);
    config.bufferMs = fminf(fmaxf(config.bufferMs, 0.0f), 50.0f);
    lsfg_log(@"profile for %@%@: frame generation %s %dx, %s mode, flow %.2f, buffer %.0f ms", exe, gamePath ? [@" from " stringByAppendingString:gamePath] : @"", config.enabled ? "on" : "off", config.multiplier,
             config.performance ? "performance" : "quality", config.flowScale, config.bufferMs);
    lsfg_log(@"profile for %@: upscaler %s", exe, config.upscaler == 1 ? (config.nssQuality == 0 ? "NSS low" : config.nssQuality == 2 ? "NSS high" : config.nssQuality == 3 ? "NSS fast" : "NSS mid") : "MetalFX");
    static const char *scalerNames[] = {"off", "LS1", "FSR", "BCAS", "bicubic", "nearest", "NIS"};
    lsfg_log(@"profile for %@: scaling %s, sharpness %.2f%s", exe, scalerNames[MAX(0, MIN(config.scaler, 6))], config.scalerSharpness,
             config.scaler == 1 && config.scalerPerformance ? ", performance" : "");
    lsfg_log(@"profile for %@: frame cap %@", exe, config.fpsCap < 0 ? @"auto" : config.fpsCap == 0 ? @"off" : [NSString stringWithFormat:@"%d fps", config.fpsCap]);
}

static void fgRebuild(void);
static void setOverlayHidden(BOOL hidden);
static void updateScaler(void);
static BOOL traceOn(void);

// The app saves profiles.json on every change; pick changes up while the game runs (checked
// once a second). On/off and the pacing buffer apply at once; the rest rebuilds the context.
// Re-reads settings and applies what changed while the game runs.
static void applyConfigChanges(void) {
    typeof(config) before = config;
    loadConfig();
    __typeof__(config) measured = before;   // the HUD's size doesn't change what it measures
    measured.hudScale = config.hudScale;
    if (memcmp(&measured, &config, sizeof config) != 0) atomic_fetch_add(&totalSettingsChanges, 1);
    if (config.enabled != before.enabled) {
        atomic_store(&fgOn, config.enabled);
        lsfg_log(@"frame generation switched %s", config.enabled ? "on" : "off");
    }
    if (config.multiplier != before.multiplier || config.performance != before.performance || config.flowScale != before.flowScale)
        fgRebuild();
    if (config.scaler != before.scaler || config.scalerSharpness != before.scalerSharpness ||
        config.scalerPerformance != before.scalerPerformance)
        dispatch_async(dispatch_get_main_queue(), ^{ updateScaler(); });
    if (config.hud != before.hud) lsfg_log(@"performance HUD %s", config.hud ? "on" : "off");
}

// Called once a second: reloads when profiles.json or the game folder's profile changes (or
// appears or goes away).
static void reloadConfigIfChanged(void) {
    static NSString *seen;
    NSMutableString *signature = [NSMutableString string];
    for (NSString *path in @[profilesPath(), gameProfilePath() ?: @""]) {
        struct stat st;
        if (path.length && stat(path.fileSystemRepresentation, &st) == 0)
            [signature appendFormat:@"%@:%ld.%ld;", path, (long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec];
    }
    if (!seen) { seen = signature; return; } // read at startup already
    if ([signature isEqualToString:seen]) return;
    seen = signature;
    applyConfigChanges();
}

#include "lsfg_capture.m"   // reference frames and capture plans

static BOOL envOn(const char *name, BOOL fallback) {
    const char *v = getenv(name);
    return v ? v[0] != '0' : fallback;
}

static BOOL loadBridge(void) {
    Dl_info info = {0};
    dladdr((void *)loadBridge, &info);
    NSString *path = [[@(info.dli_fname ?: ".") stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"liblsfgbridge.dylib"];
    void *lib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { lsfg_log(@"frame generation off: cannot load %@: %s", path, dlerror()); return NO; }
    bridge.create = (bridge_create_fn)dlsym(lib, "lsfg_bridge_create");
    bridge.input = (bridge_texture_fn)dlsym(lib, "lsfg_bridge_input");
    bridge.encode = (bridge_encode_fn)dlsym(lib, "lsfg_bridge_encode");
    bridge.output = (bridge_output_fn)dlsym(lib, "lsfg_bridge_output");
    bridge.destroy = (bridge_destroy_fn)dlsym(lib, "lsfg_bridge_destroy");
    return bridge.create && bridge.input && bridge.encode && bridge.output && bridge.destroy;
}

// Lossless Scaling's spatial upscalers (lss-metal's C API, liblssbridge.dylib next to this library).
typedef void *(*lss_create_fn)(const void *, int, int, int, int, unsigned, int, float, int, char *, int);
typedef int (*lss_encode_fn)(void *, const void *, const void *, const void *, int, int);
typedef void (*lss_destroy_fn)(void *);
static struct { lss_create_fn create; lss_encode_fn encode; lss_destroy_fn destroy; } lss;
static BOOL scaleAvailable;

static BOOL loadScaleBridge(void) {
    Dl_info info = {0};
    dladdr((void *)loadScaleBridge, &info);
    NSString *path = [[@(info.dli_fname ?: ".") stringByDeletingLastPathComponent]
                      stringByAppendingPathComponent:@"liblssbridge.dylib"];
    void *lib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!lib) { lsfg_log(@"scaling unavailable: cannot load %@: %s", path, dlerror()); return NO; }
    lss.create = (lss_create_fn)dlsym(lib, "lss_bridge_create");
    lss.encode = (lss_encode_fn)dlsym(lib, "lss_bridge_encode");
    lss.destroy = (lss_destroy_fn)dlsym(lib, "lss_bridge_destroy");
    return lss.create && lss.encode && lss.destroy;
}

// The upscaler the display link draws with: the game's frame (in) into an aspect-fit rect (out) of the overlay's
// drawable (canvas, the window's real pixels). NULL: frames are shown at their own size.
typedef struct { void *ctx; int inW, inH, outW, outH, outX, outY, canvasW, canvasH, mode, perf; float sharpness; } ScaleCtx;
static ScaleCtx *_Atomic scaleCurrent;
static _Atomic bool scaleUpdateQueued;   // an updateScaler is queued or its upscaler is still being built
static BOOL scalerWanted(void) { return scaleAvailable && config.scaler != 0; }
// The overlay is needed even without frame generation: to scale the game's frames, or to draw the HUD on them.
static BOOL overlayWanted(void) { return scalerWanted() || (fgAvailable && config.hud); }
// The Lightscale icon, for the first 5 seconds the overlay shows the game: fades in and out over 0.3 s. Returns its
// opacity (0: gone). Display link thread.
static float badgeAlpha(void) {
    static CFTimeInterval start;
    const CFTimeInterval now = CACurrentMediaTime();
    if (start == 0) start = now;
    const double t = now - start;
    return t >= 5 ? 0 : (float)fmin(1, fmin(t, 5 - t) / 0.3);
}
// The overlay's width in points (main thread writes it), for the HUD's pixels per point.
static _Atomic double overlayPointsWide;

// Ring textures for the frames being shown. Rings only grow (a later 2x → 4x reuses them).
static void allocateRings(id<MTLDevice> device, NSUInteger w, NSUInteger h, MTLPixelFormat format, int multiplier) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    for (int i = 0; i < kSlots; i++) {
        if (!realRing[i]) realRing[i] = [device newTextureWithDescriptor:d];
        for (int j = 0; j < multiplier - 1 && j < kMaxGenerated; j++)
            if (!genRing[i][j]) genRing[i][j] = [device newTextureWithDescriptor:d];
    }
}

// Builds the LSFG context and ring textures in the background (pipelines can take a moment).
static void fgCreateContext(id<MTLDevice> device, id<MTLTexture> frame) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&fgState, &expected, 1)) return;
    NSUInteger w = frame.width, h = frame.height;
    MTLPixelFormat format = frame.pixelFormat;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char error[512] = {0};
        float flow = config.flowScale;
        BOOL perf = config.performance;
        CFTimeInterval t0 = CACurrentMediaTime();
        void *ctx = bridge.create((__bridge const void *)device, (int)w, (int)h, (unsigned)format, config.multiplier, flow, perf, error, sizeof error);
        if (!ctx) {
            lsfg_log(@"frame generation unavailable (the HUD and display path still work): %s", error);
            lsfgMissing = YES;
        }
        fgDevice = device;
        allocateRings(device, w, h, format, ctx ? config.multiplier : 1);
        presentQueue = [device newCommandQueue];
        presenter = dispatch_queue_create("lsfg.presenter", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        slotsFree = dispatch_semaphore_create(kSlots);
        fgContext = ctx;
        fgWidth = w; fgHeight = h; fgFormat = format;
        atomic_store(&fgState, 2);
        if (!ctx) return;
        lsfg_log(@"frame generation ready: %lux%lu fmt %lu, flow %.2f, %s mode, built in %.2fs", (unsigned long)w,
                 (unsigned long)h, (unsigned long)format, flow, perf ? "performance" : "quality", CACurrentMediaTime() - t0);
    });
}

// New settings that change the LSFG context (multiplier, mode, motion detail): build a new one
// in the background; the game's next frame swaps it in (fgEncode) and frees the old one.
static void fgRebuild(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("lsfg.rebuild", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        id<MTLDevice> device = fgDevice;
        if (atomic_load(&fgState) != 2 || !device || lsfgMissing) return;
        char error[512] = {0};
        int multiplier = config.multiplier;
        float flow = config.flowScale;
        BOOL perf = config.performance;
        CFTimeInterval t0 = CACurrentMediaTime();
        void *ctx = bridge.create((__bridge const void *)device, (int)fgWidth, (int)fgHeight, (unsigned)fgFormat,
                                  multiplier, flow, perf, error, sizeof error);
        if (!ctx) { lsfg_log(@"settings not applied: %s", error); return; }
        allocateRings(device, fgWidth, fgHeight, fgFormat, multiplier);
        void *older = atomic_exchange(&fgPending, ctx);
        if (older) bridge.destroy(older); // never used: a newer change came in first
        lsfg_log(@"frame generation rebuilt: %dx, flow %.2f, %s mode, in %.2fs", multiplier, flow,
                 perf ? "performance" : "quality", CACurrentMediaTime() - t0);
    });
}

static void setOverlayHidden(BOOL hidden) {
    if (atomic_exchange(&overlayHidden, hidden) == hidden) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        overlay.hidden = atomic_load(&overlayHidden);
        [CATransaction commit];
    });
}

static void startDisplayLink(CAMetalLayer *layer);

// The overlay draws in the game's pixel format and colour space (10-bit HDR10 when the game's HDR is on), and the
// HUD converts its colours to match (main thread).
static void matchGameColor(CAMetalLayer *o, CAMetalLayer *game) {
    const BOOL changed = o.pixelFormat != game.pixelFormat || !CFEqual(o.colorspace ?: (CGColorSpaceRef)kCFNull, game.colorspace ?: (CGColorSpaceRef)kCFNull)
        || o.wantsExtendedDynamicRangeContent != game.wantsExtendedDynamicRangeContent
        || o.EDRMetadata != game.EDRMetadata;
    o.pixelFormat = game.pixelFormat;
    o.colorspace = game.colorspace;
    o.wantsExtendedDynamicRangeContent = game.wantsExtendedDynamicRangeContent;
    o.EDRMetadata = game.EDRMetadata;   // HDR10 metadata: how macOS tone-maps the game's PQ frames to this display
    static BOOL logged;
    if (changed || !logged) {
        logged = YES;
        CFStringRef name = game.colorspace ? CGColorSpaceCopyName(game.colorspace) : NULL;
        lsfg_log(@"overlay colour: format %lu, colour space %@, EDR %d, HDR metadata %@ -> HUD %s", (unsigned long)game.pixelFormat,
                 name ? (__bridge NSString *)name : @"none", game.wantsExtendedDynamicRangeContent,
                 game.EDRMetadata ?: @"none", lsfgHudSetColorSpace(game.colorspace));
        if (name) CFRelease(name);
    }
}

// Puts our overlay layer on top of the game's layer (main thread; ready a moment later).
static void attachOverlay(CAMetalLayer *game) {
    int expected = 0;
    if (!game || !atomic_compare_exchange_strong(&overlayState, &expected, 1)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *o = [CAMetalLayer layer];
        o.device = game.device;
        matchGameColor(o, game);
        o.framebufferOnly = NO;
        o.drawableSize = game.drawableSize;
        o.contentsScale = game.contentsScale;
        o.contentsGravity = game.contentsGravity;
        o.displaySyncEnabled = game.displaySyncEnabled;
        o.maximumDrawableCount = 3;
        o.opaque = YES;
        o.frame = game.bounds;
        o.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [game addSublayer:o];
        [CATransaction commit];
        overlay = o;
        startDisplayLink(o);
        atomic_store(&overlayState, 2);
        updateScaler();
        lsfg_log(@"overlay attached: %.0fx%.0f on %@", o.drawableSize.width, o.drawableSize.height, NSStringFromClass([game class]));
    });
}

// Backing scale of the screen showing `layer`'s window (1 if it isn't found).
static CGFloat screenScaleOf(CALayer *layer) {
    CALayer *root = layer;
    while (root.superlayer) root = root.superlayer;
    for (NSWindow *w in NSApp.windows) {
        CALayer *l = w.contentView.layer;
        while (l.superlayer) l = l.superlayer;
        if (l == root) return (w.screen ?: NSScreen.mainScreen).backingScaleFactor;
    }
    return NSScreen.mainScreen ? NSScreen.mainScreen.backingScaleFactor : 1;
}

// The game can swap to a new layer mid-session (D3DMetal does when the swapchain is recreated, e.g. when the game's
// own frame generation is switched on). The overlay must sit on the layer the frames come from, or it shows nothing
// while the game's presents are held back for it: move it there (main thread). True if it's already there.
static _Atomic bool overlayMoving;
static BOOL overlayOnGameLayer(void) {
    CAMetalLayer *o = overlay, *game = fgLayer;
    if (!o || !game) return YES;
    const BOOL sameFormat = o.pixelFormat == game.pixelFormat;
    if (o.superlayer == game && sameFormat) {
        if (o.EDRMetadata != game.EDRMetadata)   // the game set or changed its HDR10 metadata: follow it, no need to wait
            dispatch_async(dispatch_get_main_queue(), ^{ if (fgLayer == game) matchGameColor(o, game); });
        return YES;
    }
    if (atomic_exchange(&overlayMoving, true)) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *g = fgLayer;
        if (g && o.superlayer == g && o.pixelFormat != g.pixelFormat) {   // same layer, new format (HDR toggled)
            matchGameColor(o, g);
            updateScaler();
        } else if (g && o.superlayer != g) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [o removeFromSuperlayer];
            matchGameColor(o, g);   // a new swapchain can bring another format (HDR switched on or off)
            o.frame = g.bounds;
            [g addSublayer:o];
            [CATransaction commit];
            lsfg_log(@"game switched to a new layer (%@ %p): overlay moved to it", NSStringFromClass([g class]), (__bridge void *)g);
            updateScaler();
        }
        atomic_store(&overlayMoving, false);
    });
    return NO;
}

// Sizes the overlay for the current scaling setting and builds the upscaler for it (main thread). With scaling on,
// the overlay's drawable has the window's real pixel size and the game's frames are upscaled into it; otherwise it
// has the frames' own size.
static void updateScaler(void) {
    CAMetalLayer *o = overlay;
    if (traceOn()) lsfg_log(@"trace scaler: overlay %@ state %d frames %lux%lu, wanted %d (bridge %d, mode %d), bounds %@ scale %.1f",
                            o, atomic_load(&overlayState), (unsigned long)fgWidth, (unsigned long)fgHeight, scalerWanted(), scaleAvailable,
                            config.scaler, NSStringFromRect(NSRectFromCGRect(o.bounds)), o.contentsScale);
    if (!o || atomic_load(&overlayState) != 2 || fgWidth == 0) { atomic_store(&scaleUpdateQueued, false); return; }
    const int inW = (int)fgWidth, inH = (int)fgHeight;
    // The window's real pixels come from its screen, not the game's layer: with CrossOver's high-resolution mode off
    // the game draws at 1x on a Retina screen, which is what there is to upscale.
    const CGFloat gameScale = o.superlayer ? o.superlayer.contentsScale : o.contentsScale;
    const CGFloat pixelScale = MAX(gameScale, screenScaleOf(o));
    const CGSize native = CGSizeMake(round(o.bounds.size.width * pixelScale), round(o.bounds.size.height * pixelScale));
    const BOOL scale = scalerWanted() && (native.width > inW + 1 || native.height > inH + 1);   // upscaling only
    const CGSize canvas = scale ? native : CGSizeMake(inW, inH);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    const CGFloat layerScale = scale ? pixelScale : gameScale;
    if (o.contentsScale != layerScale) o.contentsScale = layerScale;
    if (!CGSizeEqualToSize(o.drawableSize, canvas)) o.drawableSize = canvas;
    [CATransaction commit];
    atomic_store(&overlayPointsWide, o.bounds.size.width);
    const int mode = config.scaler, perf = config.scalerPerformance;
    const float sharpness = config.scalerSharpness;
    id<MTLDevice> device = fgDevice;
    const MTLPixelFormat format = fgFormat;
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("lsfg.scaler", DISPATCH_QUEUE_SERIAL); });
    atomic_store(&scaleUpdateQueued, true);   // until the swap below: the display link waits instead of asking again
    dispatch_async(queue, ^{
        ScaleCtx *cur = atomic_load(&scaleCurrent);
        if (scale && cur && cur->inW == inW && cur->inH == inH && cur->canvasW == (int)canvas.width &&
            cur->canvasH == (int)canvas.height && cur->mode == mode && cur->perf == perf && cur->sharpness == sharpness) {
            atomic_store(&scaleUpdateQueued, false);   // already what's wanted
            return;
        }
        ScaleCtx *next = NULL;
        if (scale && device) {
            const double f = MIN(canvas.width / inW, canvas.height / inH);
            const int ow = (int)llround(inW * f), oh = (int)llround(inH * f);
            char error[512] = {0};
            CFTimeInterval t0 = CACurrentMediaTime();
            void *ctx = lss.create((__bridge const void *)device, inW, inH, ow, oh, (unsigned)format, mode, sharpness, perf, error, sizeof error);
            if (!ctx) {
                lsfg_log(@"scaling off: %s", error);
            } else {
                next = calloc(1, sizeof *next);
                *next = (ScaleCtx){ ctx, inW, inH, ow, oh, ((int)canvas.width - ow) / 2, ((int)canvas.height - oh) / 2,
                                    (int)canvas.width, (int)canvas.height, mode, perf, sharpness };
                lsfg_log(@"scaling %dx%d -> %dx%d in a %.0fx%.0f window (mode %d, sharpness %.2f), set up in %.2fs", inW, inH,
                         ow, oh, canvas.width, canvas.height, mode, sharpness, CACurrentMediaTime() - t0);
            }
        } else if (scalerWanted()) {
            lsfg_log(@"scaling: frames are %dx%d, the window %.0fx%.0f: nothing to upscale", inW, inH, native.width, native.height);
        }
        ScaleCtx *old = atomic_exchange(&scaleCurrent, next);
        atomic_store(&scaleUpdateQueued, false);
        if (old) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), queue, ^{ lss.destroy(old->ctx); free(old); });
    });
}

static BOOL traceOn(void) { static int on = -1; if (on < 0) on = envOn("LSFG_TRACE", NO); return on; }

// Presentation is driven by a CAMetalDisplayLink on the overlay: once per display refresh it
// hands us a drawable due for that refresh, and we show the newest queued frame whose time has
// come. Frames (generated ones, then the real one) are queued when the GPU finishes them, at times
// on a steady cadence. Nothing holds drawables ahead of time and nothing hand-times presents, so
// the game is never throttled and pacing locks to the real refresh. (Timed presents with the
// overlay's 3 drawables capped 4x at ~60 fps or dropped every frame.)
typedef struct { int slot; int index; CFTimeInterval at; } QueuedFrame; // index == -1: real frame
enum { kQueueCapacity = 64 };
static QueuedFrame frameQueue[kQueueCapacity];
static int queueHead, queueCount;
static int slotRemaining[kSlots];               // frames of a slot not yet shown or skipped
static os_unfair_lock queueLock = OS_UNFAIR_LOCK_INIT;
static CAMetalDisplayLink *displayLink;
// The display link's own clock: when its latest refresh will appear, and the refresh interval.
// Frames are scheduled against this, since an update's target lies a few refreshes in the future.
static _Atomic double linkTarget, linkInterval;

// A frame is done (shown and copied, or skipped). The slot's textures are reusable after its last.
static void releaseFrameLocked(QueuedFrame f) {
    if (--slotRemaining[f.slot] == 0) dispatch_semaphore_signal(slotsFree);
}

// The display's real refresh interval: Low Power Mode caps ProMotion displays at 60 Hz while still
// reporting (and ticking the display link at) 120.
// The display's nominal refresh rate (read on the main thread, AppKit isn't thread-safe), in seconds per refresh.
static _Atomic double screenRefresh;
static void readScreenRefresh(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSScreen *screen = NSScreen.mainScreen;   // the screen with the game's window, most likely
        double hz = screen.maximumFramesPerSecond;
        if (hz <= 0) for (NSScreen *s in NSScreen.screens) hz = MAX(hz, (double)s.maximumFramesPerSecond);
        if (hz > 0) atomic_store(&screenRefresh, 1.0 / hz);
    });
}

static double effectiveRefresh(void) {
    return MAX(atomic_load(&linkInterval), NSProcessInfo.processInfo.lowPowerModeEnabled ? 1.0 / 60 : 0);
}

// Frame generation stepped aside because the game runs too fast for generated frames (fgShouldRun).
static _Atomic bool fgSteppedAside;
static BOOL fgShowing(void) { return (atomic_load(&fgOn) && !atomic_load(&fgSteppedAside)) || overlayWanted(); }
static BOOL fgRunLSFG;   // this frame: frame generation runs (otherwise frames are only captured, for scaling)

// Display times follow a steady cadence: each frame continues from the previous real frame's
// target, so the game's frame-time jitter doesn't reach the screen. The cadence only snaps to
// "now" when frames arrive too late, and never runs far ahead (bounded latency).
static CFTimeInterval lastRealTarget;
static double adaptiveBuffer; // seconds; see presentSlot
static void presentSlot(int slot, int generated, CFTimeInterval completedAt) {
    CFTimeInterval period = MIN(frameInterval > 0 ? frameInterval : 1.0 / 30, 0.1);
    // Show only as many frames per real frame as the display can: Low Power Mode caps ProMotion
    // displays at 60 Hz while still reporting (and ticking the display link at) 120. Pick the
    // generated frames evenly, e.g. 4x at 30 fps on 60 Hz shows the middle one: a clean 2x.
    double refresh = effectiveRefresh();
    int fit = refresh > 0 ? MAX(1, (int)llround(period / refresh)) : generated + 1;
    int shown = MIN(generated + 1, fit);
    int picks[kMaxGenerated + 1];
    for (int k = 1; k < shown; k++) picks[k - 1] = (int)llround((double)k * (generated + 1) / shown) - 1;
    picks[shown - 1] = -1; // the real frame
    CFTimeInterval step = period / shown;
    // The buffer is headroom for frames that finish late. The setting is its minimum: each time a
    // batch arrives after its slot on the cadence (its frames would pile onto one refresh and all
    // but one be skipped), the buffer grows by how late it was, up to 30 ms; while frames arrive in
    // time it shrinks back by 0.1 ms per real frame. On the Metal 4 path, where LSFG starts only
    // once the game's whole frame is done, 8 ms showed half the frames at 4x and 20 ms nearly all.
    double minBuffer = config.bufferMs / 1000.0; // read every frame: changes apply live
    if (adaptiveBuffer < minBuffer) adaptiveBuffer = minBuffer;
    // Earliest a new frame can appear: the refresh after the link's latest one.
    double target = atomic_load(&linkTarget);
    CFTimeInterval earliest = target > 0 ? target + (refresh > 0 ? refresh : 1.0 / 120) : CACurrentMediaTime() + 0.003;
    CFTimeInterval first = lastRealTarget > 0 ? lastRealTarget + step : earliest;
    if (first < earliest) {                                                  // fell behind: restart the cadence
        if (lastRealTarget > 0) {
            adaptiveBuffer = MIN(0.030, adaptiveBuffer + (earliest - first) + 0.001);
            bump(kLateBatches);
        }
        first = earliest + adaptiveBuffer;
    } else {
        adaptiveBuffer = MAX(minBuffer, adaptiveBuffer - 0.0001);
    }
    if (first > earliest + adaptiveBuffer + period / 2) first = earliest + adaptiveBuffer; // drifted ahead: pull latency back in
    lastRealTarget = first + (shown - 1) * step;
    atomic_fetch_add(&queueAheadUs, (long)((lastRealTarget - CACurrentMediaTime()) * 1e6));
    atomic_fetch_add(&queueAheadCount, 1);
    if (traceOn()) {
        static int n;
        if (n++ < 12) lsfg_log(@"trace slot %d: %.1f ms after GPU completion, %d generated from +%.1f ms, step %.1f ms",
                               slot, (CACurrentMediaTime() - completedAt) * 1000, generated,
                               (first - CACurrentMediaTime()) * 1000, step * 1000);
    }
    os_unfair_lock_lock(&queueLock);
    slotRemaining[slot] = shown;
    for (int i = 0; i < shown && queueCount < kQueueCapacity; i++) {
        frameQueue[(queueHead + queueCount++) % kQueueCapacity] = (QueuedFrame){ slot, picks[i], first + i * step };
    }
    os_unfair_lock_unlock(&queueLock);
}

// GPU timestamps for the HUD (below, with LSFG's timing): per-kind rings of slots.
enum { kLsfgTimingSlots = 32, kTimingLsfg = 0, kTimingDisplay = 1 };
static int timingSlot(id<MTLDevice> device, int kind);
static double timingRead(int slot);
static void timingBracket(id<MTLCommandBuffer> cb, int slot, BOOL after, id<MTLTexture> finished);

@interface LSFGDisplayLinkTarget : NSObject <CAMetalDisplayLinkDelegate>
@end

@implementation LSFGDisplayLinkTarget
- (void)metalDisplayLink:(CAMetalDisplayLink *)link needsUpdate:(CAMetalDisplayLinkUpdate *)update {
    @autoreleasepool { [self showFrameFor:update]; }
}

- (void)showFrameFor:(CAMetalDisplayLinkUpdate *)update {
    bump(kLinkUpdates);
    CFTimeInterval now = update.targetPresentationTimestamp, previous = atomic_exchange(&linkTarget, now);
    if (previous > 0 && now > previous && now - previous < 0.05) {
        double interval = atomic_load(&linkInterval);
        atomic_store(&linkInterval, interval > 0 ? interval * 0.9 + (now - previous) * 0.1 : now - previous);
    }
    // Show the newest frame due by this refresh (half a refresh of slack); skip older ones.
    double refresh = atomic_load(&linkInterval);
    CFTimeInterval due = now + (refresh > 0 ? refresh / 2 : 0.004);
    BOOL found = NO;
    QueuedFrame show = {0};
    os_unfair_lock_lock(&queueLock);
    while (queueCount > 0 && frameQueue[queueHead].at <= due) {
        if (found) releaseFrameLocked(show); // superseded before it reached the screen
        show = frameQueue[queueHead];
        found = YES;
        queueHead = (queueHead + 1) % kQueueCapacity;
        queueCount--;
    }
    os_unfair_lock_unlock(&queueLock);
    if (!found) return; // nothing new: the previous frame stays on screen

    id<CAMetalDrawable> drawable = update.drawable;
    id<MTLTexture> frame = show.index < 0 ? realRing[show.slot] : genRing[show.slot][show.index], dst = drawable.texture;
    ScaleCtx *sc = atomic_load(&scaleCurrent);
    const BOOL scaled = sc && (int)dst.width == sc->canvasW && (int)dst.height == sc->canvasH &&
                        (int)frame.width == sc->inW && (int)frame.height == sc->inH;
    if (!scaled && (dst.width != frame.width || dst.height != frame.height)) {
        // the overlay is being resized for a scaling change: wait for its new size (or upscaler)
        if (!atomic_exchange(&scaleUpdateQueued, true)) dispatch_async(dispatch_get_main_queue(), ^{ updateScaler(); });
        os_unfair_lock_lock(&queueLock);
        releaseFrameLocked(show);
        os_unfair_lock_unlock(&queueLock);
        return;
    }
    id<MTLCommandBuffer> cb = [presentQueue commandBuffer];
    const int timing = config.hud ? timingSlot(cb.device, kTimingDisplay) : -1;
    if (timing >= 0) timingBracket(cb, timing, NO, nil);
    if (scaled) {
        if (sc->outW < sc->canvasW || sc->outH < sc->canvasH) {   // letterbox: black around the picture
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = dst;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        }
        lss.encode(sc->ctx, (__bridge const void *)cb, (__bridge const void *)frame, (__bridge const void *)dst, sc->outX, sc->outY);
    } else {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:frame toTexture:dst];
        [blit endEncoding];
    }
    const float badge = badgeAlpha();
    if (show.index < 0) captureEncode(kCaptureFinal, cb, dst, overlay.colorspace);   // a plan's frames: as shown, before the HUD
    if (config.hud || badge > 0) {
        const double points = atomic_load(&overlayPointsWide);
        const float pixelsPerPoint = points > 0 ? (float)(dst.width / points) : 1.0f;
        static bool logged;
        if (!logged) { logged = true; lsfg_log(@"HUD: drawing on %lux%lu at %.2f px/pt", (unsigned long)dst.width, (unsigned long)dst.height, pixelsPerPoint); }
        lsfgHudEncode(cb, dst, pixelsPerPoint * config.hudScale, config.hud, badge, 40 / config.hudScale);   // 40 pt whatever the HUD's size
    }
    if (timing >= 0) timingBracket(cb, timing, YES, dst);
    trackPresented(drawable);
    [cb presentDrawable:drawable];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        os_unfair_lock_lock(&queueLock);
        releaseFrameLocked(show);
        os_unfair_lock_unlock(&queueLock);
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        // the pass's own GPU time when it has timestamps, else the command buffer's span
        double ns = timing >= 0 ? timingRead(timing) : -1;
        if (ns >= 0) {
            const unsigned i = atomic_fetch_add(&displayPassNext, 1) % kDisplayPassRing;
            atomic_store(&displayPassSettings[i], atomic_load(&totalSettingsChanges));
            atomic_store(&displayPassNs[i], (long)ns);
        }
        if (ns < 0 && done.GPUEndTime > done.GPUStartTime) ns = (done.GPUEndTime - done.GPUStartTime) * 1e9;
        atomic_fetch_add(&totalDisplayPasses, 1);
        if (ns >= 0) {
            atomic_fetch_add(&linkGpuUs, (long)(ns / 1e3));
            atomic_fetch_add(&totalDisplayNs, (long)ns);
            atomic_fetch_add(&linkGpuCount, 1);
        }
    }];
    // Back on after being switched off: reveal the overlay once it holds a fresh frame.
    if (atomic_load(&overlayHidden) && fgShowing())
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { if (fgShowing()) setOverlayHidden(NO); }];
    [cb commit];
    if (show.index >= 0) bump(kGenerated);
}
@end

// Runs the display link on its own thread (not the game's, not Wine's main thread).
static void startDisplayLink(CAMetalLayer *layer) {
    static LSFGDisplayLinkTarget *target;
    target = [LSFGDisplayLinkTarget new];
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        displayLink = [[CAMetalDisplayLink alloc] initWithMetalLayer:layer];
        displayLink.delegate = target;
        // Ask for the display's full rate: 4x needs every refresh of a 120 Hz screen.
        float maxRate = 120;
        for (NSScreen *screen in NSScreen.screens) maxRate = MAX(maxRate, (float)screen.maximumFramesPerSecond);
        displayLink.preferredFrameRateRange = CAFrameRateRangeMake(maxRate, maxRate, maxRate);
        [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSDefaultRunLoopMode];
        while (true) @autoreleasepool { [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture]; }
    }];
    thread.name = @"lsfg.displaylink";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [thread start];
}

// Commit hook, for the command buffer that renders a real frame into drawable texture `target`.
// Encodes frame generation for one real frame into `cb`. `targetRead` (may be nil) is called once
// every read of the game's frame `target` is encoded, before LSFG's own work (the Metal 4 path
// lets the game continue from there). Not called if the frame isn't used.
// True while frames should be generated and shown: frame generation is on, and the game isn't
// running so fast that no generated frame would fit between its own (above about half the
// display's refresh rate, e.g. 80 fps menus on 120 Hz). Otherwise the game presents its own frames,
// LSFG does no work, and it's primed afresh when it resumes. Called once per real frame.
static BOOL fgShouldRun(void) {
    static CFTimeInterval lastFrame, gameInterval;
    CFTimeInterval now = CACurrentMediaTime(), dt = now - lastFrame;
    lastFrame = now;
    if (dt > 0.002 && dt < 0.25) gameInterval = gameInterval > 0 ? gameInterval * 0.9 + dt * 0.1 : dt;
    if (dt > 0 && dt < 0.25) lsfgHudGameFrame((float)(dt * 1000));

    // Hysteresis around the point where a generated frame starts to fit (1.5 refreshes).
    double refresh = effectiveRefresh();
    BOOL aside = atomic_load(&fgSteppedAside);
    if (refresh > 0 && gameInterval > 0) {
        if (!aside && gameInterval < 1.45 * refresh) {
            atomic_store(&fgSteppedAside, true); aside = YES;
            lsfg_log(@"game at %.0f fps, above half the %.0f Hz display: showing its own frames", 1 / gameInterval, 1 / refresh);
        } else if (aside && gameInterval > 1.6 * refresh) {
            atomic_store(&fgSteppedAside, false); aside = NO;
            lsfg_log(@"game at %.0f fps: frame generation back on", 1 / gameInterval);
        }
    }
    fgRunLSFG = atomic_load(&fgOn) && !aside && !lsfgMissing;
    if (fgRunLSFG) return YES;
    fgWarmup = 1;                 // LSFG's history goes stale meanwhile: prime it again when it resumes
    if (overlayWanted()) return YES;   // the overlay still shows the game's own frames, upscaled or with the HUD
    if (atomic_load(&overlayState) == 2) setOverlayHidden(YES);
    return NO;
}

// GPU times for the HUD, from timestamps around the work rather than the command buffer's start and end (which also
// count the time it waits while the GPU runs the game's work):
// - LSFG: a timestamp at the end of the copy into LSFG and one at the start of the copy out of it;
// - the overlay's display pass: around everything it encodes, with a tiny blit before and after as the markers.
// Each kind has a ring of slots, read back when the command buffer completes. GPU ticks are converted with a rate
// measured against the CPU clock over the first half second.
static id<MTLCounterSampleBuffer> lsfgSamples;
static _Atomic double lsfgTicksPerNs;   // 0 until measured
static _Atomic unsigned lsfgNextSlot;

static id<MTLBuffer> timingMarker;   // what the marker blits fill: 4 bytes nobody reads

static int timingSlot(id<MTLDevice> device, int kind) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (![device supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary]) return;
        id<MTLCounterSet> timestamps = nil;
        for (id<MTLCounterSet> set in device.counterSets)
            if ([set.name isEqualToString:MTLCommonCounterSetTimestamp]) timestamps = set;
        if (!timestamps) return;
        MTLCounterSampleBufferDescriptor *d = [MTLCounterSampleBufferDescriptor new];
        d.counterSet = timestamps;
        d.sampleCount = 2 * 2 * kLsfgTimingSlots;
        d.storageMode = MTLStorageModeShared;
        NSError *error = nil;
        lsfgSamples = [device newCounterSampleBufferWithDescriptor:d error:&error];
        if (!lsfgSamples) { lsfg_log(@"HUD: no GPU timestamps (%@)", error.localizedDescription); return; }
        timingMarker = [device newBufferWithLength:16 options:MTLResourceStorageModePrivate];
        MTLTimestamp cpu0, gpu0;
        [device sampleTimestamps:&cpu0 gpuTimestamp:&gpu0];
        const CFTimeInterval t0 = CACurrentMediaTime();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            MTLTimestamp cpu1, gpu1;
            [device sampleTimestamps:&cpu1 gpuTimestamp:&gpu1];
            const double ns = (CACurrentMediaTime() - t0) * 1e9;
            if (gpu1 > gpu0 && ns > 0) atomic_store(&lsfgTicksPerNs, (gpu1 - gpu0) / ns);
        });
    });
    if (!lsfgSamples || atomic_load(&lsfgTicksPerNs) <= 0) return -1;
    static _Atomic unsigned displayNextSlot;
    _Atomic unsigned *next = kind == kTimingDisplay ? &displayNextSlot : &lsfgNextSlot;
    return kind * kLsfgTimingSlots + (int)(atomic_fetch_add(next, 1) % kLsfgTimingSlots);
}
static int lsfgTimingSlot(id<MTLDevice> device) { return timingSlot(device, kTimingLsfg); }

// The blit pass before LSFG (after: NO) samples at its end, the one after LSFG at its start.
static MTLBlitPassDescriptor *lsfgTimingPass(int slot, BOOL after) {
    MTLBlitPassDescriptor *pass = [MTLBlitPassDescriptor blitPassDescriptor];
    if (slot >= 0) {
        MTLBlitPassSampleBufferAttachmentDescriptor *a = pass.sampleBufferAttachments[0];
        a.sampleBuffer = lsfgSamples;
        a.startOfEncoderSampleIndex = after ? 2 * slot + 1 : MTLCounterDontSample;
        a.endOfEncoderSampleIndex = after ? MTLCounterDontSample : 2 * slot;
    }
    return pass;
}

// The time between a slot's two timestamps in ns, or -1.
static double timingRead(int slot) {
    NSData *data = [lsfgSamples resolveCounterRange:NSMakeRange(2 * slot, 2)];
    if (data.length < 2 * sizeof(MTLCounterResultTimestamp)) return -1;
    const MTLCounterResultTimestamp *t = data.bytes;
    const double rate = atomic_load(&lsfgTicksPerNs);
    if (t[0].timestamp == MTLCounterErrorValue || t[1].timestamp == MTLCounterErrorValue || t[1].timestamp <= t[0].timestamp || rate <= 0) return -1;
    const double ns = (t[1].timestamp - t[0].timestamp) / rate;
    return ns > 0 && ns < 1e8 ? ns : -1;
}

// A tiny blit timestamped on its outer edge, its start before the pass (after: NO) and its end after it (YES):
// brackets a pass made of other encoders, and stays right if Metal merges it with the blit next to it. The GPU runs
// encoders that don't depend on each other at the same time, so the closing one reads a pixel of `finished` (the
// texture the pass writes): it then waits for every write to it.
static void timingBracket(id<MTLCommandBuffer> cb, int slot, BOOL after, id<MTLTexture> finished) {
    MTLBlitPassDescriptor *pass = [MTLBlitPassDescriptor blitPassDescriptor];
    MTLBlitPassSampleBufferAttachmentDescriptor *a = pass.sampleBufferAttachments[0];
    a.sampleBuffer = lsfgSamples;
    a.startOfEncoderSampleIndex = after ? MTLCounterDontSample : 2 * slot;
    a.endOfEncoderSampleIndex = after ? 2 * slot + 1 : MTLCounterDontSample;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoderWithDescriptor:pass];
    if (finished)
        [blit copyFromTexture:finished sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(1, 1, 1)
                     toBuffer:timingMarker destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    else
        [blit fillBuffer:timingMarker range:NSMakeRange(0, 4) value:0];
    [blit endEncoding];
}

static void lsfgTimingCollect(int slot) {
    const double ns = timingRead(slot);
    if (ns < 0) return;
    atomic_fetch_add(&totalLsfgNs, (long)ns);
    atomic_fetch_add(&totalLsfgFrames, 1);
}

static void fgEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target, void (^targetRead)(id<MTLCommandBuffer>)) {
    int state = atomic_load(&fgState);
    if (state == 0) fgCreateContext(cb.device, target);
    if (state != 2) return;
    void *rebuilt = atomic_exchange(&fgPending, NULL);
    if (rebuilt) {
        // New settings: swap contexts. The old one is freed once the GPU is done with it.
        void *old = fgContext;
        fgContext = rebuilt;
        fgWarmup = 1;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
                           ^{ bridge.destroy(old); });
        }];
    }
    if (target.width != fgWidth || target.height != fgHeight || target.pixelFormat != fgFormat) {
        if (atomic_exchange(&overlayState, -1) == 2) {
            lsfg_log(@"frame size or format changed; frame generation off (restart the game)");
            CAMetalLayer *o = overlay;
            dispatch_async(dispatch_get_main_queue(), ^{ [o removeFromSuperlayer]; });
        }
        return;
    }
    int ov = atomic_load(&overlayState);
    if (ov == 0) attachOverlay(fgLayer);
    if (ov == 2 && !overlayOnGameLayer()) ov = 1;   // being moved: the game presents itself meanwhile
    // Until the overlay is ready the game keeps presenting itself. A fresh context (or frame
    // generation just switched back on) has no history yet: its first frame only primes it, and
    // the game presents that one itself too.
    BOOL capture = ov == 2;
    // While LSFG primes (no history yet) the game shows its own frame, unless scaling needs the overlay anyway.
    BOOL priming = NO;
    if (fgRunLSFG && fgWarmup > 0) { fgWarmup--; priming = YES; if (!overlayWanted()) capture = NO; }

    // A slot frees up when the display has shown (or skipped) its frames. If none frees up within
    // 2 ms (game running faster than the slots cover, or the display link slowed down because the
    // window is covered), skip showing this real frame instead of stalling the game. Frames already
    // queued keep showing; LSFG is still fed, so later generated frames stay correct.
    int slot = -1;
    if (capture) {
        CFTimeInterval waitStart = CACurrentMediaTime();
        if (dispatch_semaphore_wait(slotsFree, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_MSEC)) == 0) {
            slot = nextSlot++ % kSlots;
        } else {
            capture = NO;
            bump(kSkipped);
        }
        atomic_fetch_add(&slotWaitUs, (long)((CACurrentMediaTime() - waitStart) * 1e6));
    }

    // Feed LSFG every real frame (this also warms up its history before the overlay is up), and
    // keep the real frame for display. These are the only reads of the game's frame.
    id<MTLTexture> input = fgContext ? (__bridge id<MTLTexture>)bridge.input(fgContext) : nil;
    // With the HUD on, GPU timestamps between the copy before LSFG and the copy after it time LSFG itself.
    const int timing = config.hud && fgRunLSFG && capture ? lsfgTimingSlot(cb.device) : -1;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoderWithDescriptor:lsfgTimingPass(timing, NO)];
    if (fgRunLSFG) [blit copyFromTexture:target toTexture:input];
    if (capture) [blit copyFromTexture:target toTexture:realRing[slot]];
    [blit endEncoding];
    captureEncode(kCaptureGame, cb, target, fgLayer.colorspace);   // reference frames, on request (lsfg_capture.m)
    if (targetRead) targetRead(cb);
    int generated = fgRunLSFG ? bridge.encode(fgContext, (__bridge const void *)cb) : 0;
    if (priming) generated = 0;
    if (!capture) return;

    blit = [cb blitCommandEncoderWithDescriptor:lsfgTimingPass(timing, YES)];
    generated = MAX(0, MIN(generated, kMaxGenerated));
    while (generated > 0 && !genRing[slot][generated - 1]) generated--;
    for (int j = 0; j < generated; j++)
        [blit copyFromTexture:(__bridge id<MTLTexture>)bridge.output(fgContext, j) toTexture:genRing[slot][j]];
    [blit endEncoding];
    os_unfair_lock_lock(&capturedLock);
    [captured addObject:@((uintptr_t)(__bridge void *)target)];
    os_unfair_lock_unlock(&capturedLock);
    bump(kCaptured);

    int count = MAX(0, MIN(generated, kMaxGenerated));
    if (timing >= 0) [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { lsfgTimingCollect(timing); }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        CFTimeInterval now = CACurrentMediaTime();
        if (done.GPUEndTime > done.GPUStartTime) {
            atomic_fetch_add(&frameGpuUs, (long)((done.GPUEndTime - done.GPUStartTime) * 1e6));
            atomic_fetch_add(&frameGpuCount, 1);
        }
        if (lastCompletion > 0) {
            CFTimeInterval dt = now - lastCompletion;
            if (dt > 0.004 && dt < 0.25) frameInterval = frameInterval > 0 ? frameInterval * 0.8 + dt * 0.2 : dt;
        }
        lastCompletion = now;
        dispatch_async(presenter, ^{ presentSlot(slot, count, now); });
    }];
}

// Metal 4 (D3DMetal in GPTK 4): the game submits MTL4 command buffers to an MTL4CommandQueue,
// which take no Metal 3 encoders. Frame generation runs on our own queue instead, ordered with the
// game's queue by two shared events: the game's queue signals once the frame is submitted (our
// work waits for it), and waits until we've copied the frame before running anything after it, so
// it can't draw into that image again before we've read it. LSFG itself overlaps the game's next
// frame.
static id<MTLCommandQueue> fgQueue;   // our queue for the Metal 4 path

static void fgEncodeMetal4(id<MTL4CommandQueue> queue, id<MTLTexture> target) {
    static id<MTLSharedEvent> submitted, copied;
    static uint64_t frame;
    if (!fgQueue) {
        fgQueue = [target.device newCommandQueue];
        submitted = [target.device newSharedEvent];
        copied = [target.device newSharedEvent];
        lsfg_log(@"frame generation on the Metal 4 path");
    }
    if (!fgShouldRun()) return;
    uint64_t n = ++frame;
    [queue signalEvent:submitted value:n];
    id<MTLCommandBuffer> cb = [fgQueue commandBuffer];
    [cb encodeWaitForEvent:submitted value:n];
    __block BOOL signaled = NO;
    fgEncode(cb, target, ^(id<MTLCommandBuffer> c) { [c encodeSignalEvent:copied value:n]; signaled = YES; });
    if (!signaled) [cb encodeSignalEvent:copied value:n];
    [cb commit];
    [queue waitForEvent:copied value:n];
}

// A game may draw into the drawable in several Metal 4 submissions per frame (TLOU Part II: the
// scene, then the UI). Each submit only records the drawable; frame generation runs once per frame,
// when the game hands the drawable to the display (signalDrawable, or present as a fallback), on
// the image as it finally is. Capturing every submission fed LSFG near-identical pairs, so the
// "generated" frames carried no new motion.
static os_unfair_lock pendingLock = OS_UNFAIR_LOCK_INIT;
static id pendingQueue;               // MTL4CommandQueue of the latest submit into the drawable
static id<MTLTexture> pendingTarget;

static void notePendingMetal4(id queue, id<MTLTexture> target) {
    os_unfair_lock_lock(&pendingLock);
    pendingQueue = queue;
    pendingTarget = target;
    os_unfair_lock_unlock(&pendingLock);
}

// Runs frame generation for `texture`'s frame if one is pending (texture nil: whatever is pending).
static void flushPendingMetal4(id<MTLTexture> texture) {
    os_unfair_lock_lock(&pendingLock);
    id queue = nil;
    id<MTLTexture> target = nil;
    if (pendingTarget && (!texture || pendingTarget == texture)) {
        queue = pendingQueue; target = pendingTarget;
        pendingQueue = nil; pendingTarget = nil;
    }
    os_unfair_lock_unlock(&pendingLock);
    if (target) fgEncodeMetal4(queue, target);
}

// Present hook for a game drawable. Returns YES if we took the frame over (it is shown on the
// overlay instead): the drawable then goes back to the game without being presented.
static BOOL fgPresent(id<CAMetalDrawable> real) {
    NSNumber *key = @((uintptr_t)(__bridge void *)real.texture);
    os_unfair_lock_lock(&capturedLock);
    BOOL ours = [captured containsObject:key];
    [captured removeObject:key];
    os_unfair_lock_unlock(&capturedLock);
    return ours;
}

#pragma mark - Hooks

static void installPresentHooks(void) {
    CFTimeInterval scanStart = CACurrentMediaTime();
    scanClasses = objc_copyClassList(&scanCount);
    Protocol *drawable = @protocol(CAMetalDrawable), *commandBuffer = @protocol(MTLCommandBuffer);
    BOOL (^isDrawable)(Class) = ^BOOL(Class c) { return conforms(c, drawable); };
    BOOL (^isCommandBuffer)(Class) = ^BOOL(Class c) { return conforms(c, commandBuffer); };

    hookAll(@selector(present), isDrawable, ^id(IMP orig) {
        return ^(id self) {
            @autoreleasepool {
                bump(kDrawablePresent);
                describeDrawable(self, "drawable.present");
                int k = atomic_fetch_add(&diagPresents, 1);
                if (k < kDiagFrames) {
                    id<MTLCommandBuffer> cb = lastDrawableCB;
                    lsfg_log(@"diag present #%d drawable texture %p on %@; last drawable-writing cb %p status %ld",
                             k, (__bridge void *)[(id<CAMetalDrawable>)self texture], threadName(),
                             (__bridge void *)cb, cb ? (long)cb.status : -1L);
                }
                if (fgAvailable) flushPendingMetal4([(id<CAMetalDrawable>)self texture]); // no signalDrawable
                if (fgAvailable && fgPresent(self)) return;
                if ([(id<CAMetalDrawable>)self layer] != overlay) trackPresented(self);
                ((void (*)(id, SEL))orig)(self, @selector(present));
            }
        };
    });
    hookAll(@selector(presentAtTime:), isDrawable, ^id(IMP orig) {
        return ^(id self, CFTimeInterval t) {
            @autoreleasepool {
                bump(kDrawablePresentAtTime);
                describeDrawable(self, "drawable.presentAtTime");
                ((void (*)(id, SEL, CFTimeInterval))orig)(self, @selector(presentAtTime:), t);
            }
        };
    });
    hookAll(@selector(presentAfterMinimumDuration:), isDrawable, ^id(IMP orig) {
        return ^(id self, CFTimeInterval d) {
            @autoreleasepool {
                bump(kDrawablePresentAfter);
                describeDrawable(self, "drawable.presentAfterMinimumDuration");
                ((void (*)(id, SEL, CFTimeInterval))orig)(self, @selector(presentAfterMinimumDuration:), d);
            }
        };
    });
    hookAll(@selector(presentDrawable:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d) {
            @autoreleasepool {
                bump(kCBPresent);
                if (conforms(object_getClass(d), drawable)) describeDrawable(d, "cmdbuf.presentDrawable");
                ((void (*)(id, SEL, id))orig)(self, @selector(presentDrawable:), d);
            }
        };
    });
    hookAll(@selector(presentDrawable:atTime:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d, CFTimeInterval t) {
            @autoreleasepool {
                bump(kCBPresentAtTime);
                ((void (*)(id, SEL, id, CFTimeInterval))orig)(self, @selector(presentDrawable:atTime:), d, t);
            }
        };
    });
    hookAll(@selector(presentDrawable:afterMinimumDuration:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d, CFTimeInterval t) {
            @autoreleasepool {
                bump(kCBPresentAfter);
                ((void (*)(id, SEL, id, CFTimeInterval))orig)(self, @selector(presentDrawable:afterMinimumDuration:), d, t);
            }
        };
    });
    BOOL (^signals)(Class) = ^BOOL(Class c) { return conforms(c, @protocol(MTL4CommandQueue)); };
    hookAll(@selector(signalDrawable:), signals, ^id(IMP orig) {
        return ^(id self, id d) {
            @autoreleasepool {
                bump(kMTL4Signal);
                if (conforms(object_getClass(d), drawable)) {
                    describeDrawable(d, "mtl4queue.signalDrawable");
                    if (fgAvailable) flushPendingMetal4([(id<CAMetalDrawable>)d texture]);
                }
                ((void (*)(id, SEL, id))orig)(self, @selector(signalDrawable:), d);
            }
        };
    });
    hookAll(@selector(waitForDrawable:), signals, ^id(IMP orig) {
        return ^(id self, id d) {
            @autoreleasepool {
                bump(kMTL4Wait);
                ((void (*)(id, SEL, id))orig)(self, @selector(waitForDrawable:), d);
            }
        };
    });
    // Diagnostics: who writes the drawable.
    hookAll(@selector(renderCommandEncoderWithDescriptor:), isCommandBuffer, ^id(IMP orig) {
        return ^id(id self, MTLRenderPassDescriptor *desc) {
            id enc = ((id (*)(id, SEL, id))orig)(self, @selector(renderCommandEncoderWithDescriptor:), desc);
            // Runs for every render pass: free what the lookups autorelease (Wine's threads never drain).
            @autoreleasepool {
            id<MTLTexture> target = desc.colorAttachments[0].texture;
            if (fgAvailable && isDrawableTexture(target))
                objc_setAssociatedObject(self, &kDrawableTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (diagActive() && isDrawableTexture(target)) {
                objc_setAssociatedObject(self, &kWritesDrawableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                lastDrawableCB = self;
                if (enc) objc_setAssociatedObject(enc, &kWritesDrawableKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                lsfg_log(@"diag render pass into drawable: cb %@ %p, encoder %@, load %lu store %lu, on %@",
                         NSStringFromClass([self class]), (__bridge void *)self, NSStringFromClass([enc class]),
                         (unsigned long)desc.colorAttachments[0].loadAction, (unsigned long)desc.colorAttachments[0].storeAction,
                         threadName());
            }
            }
            return enc;
        };
    });
    hookAll(@selector(blitCommandEncoder), isCommandBuffer, ^id(IMP orig) {
        return ^id(id self) {
            id enc = ((id (*)(id, SEL))orig)(self, @selector(blitCommandEncoder));
            // Weak link back so a copy into a drawable can find its command buffer.
            if (diagActive() && enc) @autoreleasepool { objc_setAssociatedObject(enc, &kOwnerKey, self, OBJC_ASSOCIATION_ASSIGN); }
            return enc;
        };
    });
    hookAll(@selector(commit), isCommandBuffer, ^id(IMP orig) {
        return ^(id self) {
            @autoreleasepool {
                if (diagActive() && objc_getAssociatedObject(self, &kWritesDrawableKey))
                    lsfg_log(@"diag commit of drawable-writing cb %p (presents so far: %d) on %@", (__bridge void *)self,
                             atomic_load(&diagPresents), threadName());
                id<MTLTexture> target = fgAvailable ? objc_getAssociatedObject(self, &kDrawableTargetKey) : nil;
                if (target) {
                    objc_setAssociatedObject(self, &kDrawableTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (fgShouldRun()) fgEncode(self, target, nil);
                }
                // Every command buffer the game commits counts toward GPU busy time (ours don't).
                id<MTLCommandQueue> owner = [(id<MTLCommandBuffer>)self commandQueue];
                if (owner != presentQueue && owner != fgQueue)
                    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> done) {
                        addGpuSpan(done.GPUStartTime, done.GPUEndTime);
                    }];
                ((void (*)(id, SEL))orig)(self, @selector(commit));
            }
        };
    });
    Protocol *renderEncoder = @protocol(MTLRenderCommandEncoder), *blitEncoder = @protocol(MTLBlitCommandEncoder);
    Protocol *computeEncoder = @protocol(MTLComputeCommandEncoder);
    hookAll(@selector(setFragmentTexture:atIndex:), ^BOOL(Class c) { return conforms(c, renderEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> t, NSUInteger index) {
            @autoreleasepool {
                if (diagActive() && objc_getAssociatedObject(self, &kWritesDrawableKey))
                    lsfg_log(@"diag drawable pass samples texture[%lu]: %@", (unsigned long)index, describeTexture(t));
                ((void (*)(id, SEL, id, NSUInteger))orig)(self, @selector(setFragmentTexture:atIndex:), t, index);
            }
        };
    });
    hookAll(@selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
            ^BOOL(Class c) { return conforms(c, blitEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> src, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz,
                 id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, MTLOrigin dor) {
            @autoreleasepool {
                if (diagActive() && isDrawableTexture(dst)) {
                    markOwnerWritesDrawable(self);
                    lsfg_log(@"diag blit copy into drawable from %@ (encoder %@) on %@", describeTexture(src),
                             NSStringFromClass([self class]), threadName());
                }
                ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))orig)(
                    self, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                    src, ss, sl, so, sz, dst, ds, dl, dor);
            }
        };
    });
    hookAll(@selector(copyFromTexture:toTexture:), ^BOOL(Class c) { return conforms(c, blitEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> src, id<MTLTexture> dst) {
            @autoreleasepool {
                if (diagActive() && isDrawableTexture(dst)) markOwnerWritesDrawable(self);
                if (diagActive() && isDrawableTexture(dst))
                    lsfg_log(@"diag blit copy (whole) into drawable from %@ on %@", describeTexture(src), threadName());
                ((void (*)(id, SEL, id, id))orig)(self, @selector(copyFromTexture:toTexture:), src, dst);
            }
        };
    });
    hookAll(@selector(setTexture:atIndex:), ^BOOL(Class c) { return conforms(c, computeEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> t, NSUInteger index) {
            @autoreleasepool {
                if (diagActive() && isDrawableTexture(t))
                    lsfg_log(@"diag compute pass binds drawable at index %lu on %@", (unsigned long)index, threadName());
                ((void (*)(id, SEL, id, NSUInteger))orig)(self, @selector(setTexture:atIndex:), t, index);
            }
        };
    });
    // Metal 4 (GPTK 4): MTL4 command buffers render into the drawable with an
    // MTL4RenderPassDescriptor; the frame is submitted with -[MTL4CommandQueue commit:count:].
    BOOL (^isMTL4CommandBuffer)(Class) = ^BOOL(Class c) { return conforms(c, @protocol(MTL4CommandBuffer)); };
    void (^noteMTL4Pass)(id, MTL4RenderPassDescriptor *) = ^(id cb, MTL4RenderPassDescriptor *desc) {
        @autoreleasepool {
            id<MTLTexture> target = desc.colorAttachments[0].texture;
            if (!isDrawableTexture(target)) return;
            if (fgAvailable) objc_setAssociatedObject(cb, &kDrawableTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (diagActive())
                lsfg_log(@"diag MTL4 render pass into drawable: cb %@ on %@", NSStringFromClass([cb class]), threadName());
        }
    };
    hookAll(@selector(renderCommandEncoderWithDescriptor:), isMTL4CommandBuffer, ^id(IMP orig) {
        return ^id(id self, MTL4RenderPassDescriptor *desc) {
            id enc = ((id (*)(id, SEL, id))orig)(self, @selector(renderCommandEncoderWithDescriptor:), desc);
            noteMTL4Pass(self, desc);
            return enc;
        };
    });
    hookAll(@selector(renderCommandEncoderWithDescriptor:options:), isMTL4CommandBuffer, ^id(IMP orig) {
        return ^id(id self, MTL4RenderPassDescriptor *desc, NSUInteger options) {
            id enc = ((id (*)(id, SEL, id, NSUInteger))orig)(self, @selector(renderCommandEncoderWithDescriptor:options:), desc, options);
            noteMTL4Pass(self, desc);
            return enc;
        };
    });
    void (^afterMTL4Commit)(id, const id *, NSUInteger) = ^(id queue, const id *buffers, NSUInteger count) {
        if (!fgAvailable) return;
        @autoreleasepool {
            for (NSUInteger i = 0; i < count; i++) {
                id<MTLTexture> target = objc_getAssociatedObject(buffers[i], &kDrawableTargetKey);
                if (!target) continue;
                objc_setAssociatedObject(buffers[i], &kDrawableTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                notePendingMetal4(queue, target);
            }
        }
    };
    // With the HUD on, the game's Metal 4 commits report their GPU time through commit feedback (Metal 4 command
    // buffers have no GPU start and end times of their own). A plain commit:count: is turned into commit:count:options:
    // with our options; a game's own options object gets our handler once.
    static _Thread_local int innerCommit;
    static char kFeedbackKey;
    hookAll(@selector(commit:count:), signals, ^id(IMP orig) {
        return ^(id self, const id *buffers, NSUInteger count) {
            bump(kMTL4Commit);
            if (config.hud && [self respondsToSelector:@selector(commit:count:options:)]) {
                MTL4CommitOptions *options = [MTL4CommitOptions new];
                [options addFeedbackHandler:^(id<MTL4CommitFeedback> fb) { addGpuSpan(fb.GPUStartTime, fb.GPUEndTime); }];
                innerCommit++;
                [(id<MTL4CommandQueue>)self commit:buffers count:count options:options];
                innerCommit--;
            } else {
                ((void (*)(id, SEL, const id *, NSUInteger))orig)(self, @selector(commit:count:), buffers, count);
            }
            afterMTL4Commit(self, buffers, count);
        };
    });
    hookAll(@selector(commit:count:options:), signals, ^id(IMP orig) {
        return ^(id self, const id *buffers, NSUInteger count, id options) {
            if (innerCommit) { ((void (*)(id, SEL, const id *, NSUInteger, id))orig)(self, @selector(commit:count:options:), buffers, count, options); return; }
            bump(kMTL4Commit);
            if (config.hud) {
                if (!options) options = [MTL4CommitOptions new];
                if (!objc_getAssociatedObject(options, &kFeedbackKey)) {
                    objc_setAssociatedObject(options, &kFeedbackKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [(MTL4CommitOptions *)options addFeedbackHandler:^(id<MTL4CommitFeedback> fb) { addGpuSpan(fb.GPUStartTime, fb.GPUEndTime); }];
                }
            }
            ((void (*)(id, SEL, const id *, NSUInteger, id))orig)(self, @selector(commit:count:options:), buffers, count, options);
            afterMTL4Commit(self, buffers, count);
        };
    });
    free(scanClasses);
    scanClasses = NULL;
    scanCount = 0;
    lsfg_log(@"class scan took %.2fs", CACurrentMediaTime() - scanStart);
    atomic_store(&diagPresents, 0);
    lsfg_log(@"present hooks installed; logging the next %d frames in detail", kDiagFrames);
}

static void installLayerHook(void) {
    Class layer = [CAMetalLayer class];
    hookAll(@selector(nextDrawable), ^BOOL(Class c) {
        for (Class k = c; k; k = class_getSuperclass(k)) if (k == layer) return YES;
        return NO;
    }, ^id(IMP orig) {
        return ^id(id self) {
            if (self == overlay) return ((id (*)(id, SEL))orig)(self, @selector(nextDrawable));
            // The GPU driver's command-buffer classes only exist once the game has a device,
            // which is certainly true by the first nextDrawable. Scanning every class takes
            // about a second, so do it off the game's present path.
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ installPresentHooks(); });
            });
            // WineMetalLayer's nextDrawable calls super: only the outermost call counts.
            static _Thread_local int depth;
            if (depth++ == 0) {
                bump(kNextDrawable);
                atomic_fetch_add(&totalGameFrames, 1);
                // Frame generation must read the drawable; framebufferOnly forbids that.
                CAMetalLayer *layer = self;
                fgLayer = layer;
                if (layer.framebufferOnly && !(getenv("LSFG_READABLE") && getenv("LSFG_READABLE")[0] == '0')) {
                    layer.framebufferOnly = NO;
                    lsfg_log(@"set framebufferOnly = NO on %@ %p", NSStringFromClass([self class]), (__bridge void *)self);
                }
            }
            id<CAMetalDrawable> drawable = ((id (*)(id, SEL))orig)(self, @selector(nextDrawable));
            if (--depth == 0 && drawable) @autoreleasepool {
                drawableTextures[atomic_fetch_add(&drawableIndex, 1) % 8] = (__bridge void *)drawable.texture;
                if (diagActive())
                    lsfg_log(@"diag nextDrawable -> texture %@ on %@", describeTexture(drawable.texture), threadName());
            }
            return drawable;
        };
    });
}

#pragma mark - Setup

static NSString *nssStatsLine(void);   // lsfg_nss_hook.m

void lsfgHudReadTotals(LSFGHudTotals *t) {
    os_unfair_lock_lock(&busyLock);
    t->gpuBusyMs = busyTotal * 1000;
    os_unfair_lock_unlock(&busyLock);
    t->gameFrames = atomic_load(&totalGameFrames);
    t->lsfgMs = atomic_load(&totalLsfgNs) / 1e6; t->lsfgFrames = atomic_load(&totalLsfgFrames);
    t->upscaleMs = atomic_load(&totalUpscaleNs) / 1e6; t->upscaleFrames = atomic_load(&totalUpscaleFrames);
    t->displayMs = atomic_load(&totalDisplayNs) / 1e6;
    t->displayPasses = atomic_load(&totalDisplayPasses);
    // the 25th percentile of the timed passes with the current settings: the pass when the game's work didn't land
    // in the middle of it
    const long settings = atomic_load(&totalSettingsChanges);
    const unsigned stored = MIN(atomic_load(&displayPassNext), (unsigned)kDisplayPassRing);
    long recent[kDisplayPassRing];
    int n = 0;
    for (unsigned i = 0; i < stored; i++)
        if (atomic_load(&displayPassSettings[i]) == settings) recent[n++] = atomic_load(&displayPassNs[i]);
    t->displayPassMs = 0;
    if (n >= 10) {
        qsort_b(recent, n, sizeof recent[0], ^int(const void *a, const void *b) {
            const long x = *(const long *)a, y = *(const long *)b;
            return x < y ? -1 : x > y;
        });
        t->displayPassMs = recent[n / 4] / 1e6;
    }
    t->lsfgInGameWork = fgQueue == nil;
    t->settingsChanges = atomic_load(&totalSettingsChanges);   // the Metal 4 path runs LSFG on its own queue
}
// The DLSS replacement's median GPU time over the last second, for the HUD (nssStatsLine sets them).
static double hudUpscaleMs;
static int hudUpscaleKind = -1;        // 0 MetalFX, 1 NSS, -1 none ran

// What the HUD shows for the last second. `c`: this second's counters.
static void publishHUD(const long *c, int shown, double mean, double sd, double max, int dropped, double fgMs, double presentMs,
                       double queuedMs, double busy) {
    LSFGHudSnapshot h = {0};
    h.screenFps = shown; h.gameFps = (int)(c[kNextDrawable] ? c[kNextDrawable] : c[kDrawablePresent]);
    h.intervalMs = mean; h.intervalSdMs = sd; h.intervalMaxMs = max; h.dropped = dropped;
    const double refresh = effectiveRefresh();
    h.refreshHz = refresh > 0 ? 1 / refresh : 0;
    h.fgGpuMs = fgRunLSFG ? fgMs : 0; h.presentGpuMs = presentMs; h.queuedMs = queuedMs; h.gpuBusy = busy;
    if (!fgAvailable) snprintf(h.frameGen, sizeof h.frameGen, "unavailable");
    else if (lsfgMissing) snprintf(h.frameGen, sizeof h.frameGen, "needs Lossless Scaling");
    else if (!atomic_load(&fgOn)) snprintf(h.frameGen, sizeof h.frameGen, "off");
    else if (atomic_load(&fgSteppedAside)) snprintf(h.frameGen, sizeof h.frameGen, "paused: game above half refresh");
    else if (config.flowScale < 0.99f)
        snprintf(h.frameGen, sizeof h.frameGen, "LSFG %d\u00d7 %s, flow %.0f%%", config.multiplier, config.performance ? "performance" : "quality", config.flowScale * 100);
    else snprintf(h.frameGen, sizeof h.frameGen, "LSFG %d\u00d7 %s", config.multiplier, config.performance ? "performance" : "quality");
    if (hudUpscaleKind == 1) {
        static const char *q[] = {"low", "mid", "high", "fast"};
        snprintf(h.upscaler, sizeof h.upscaler, "NSS %s", q[MAX(0, MIN(config.nssQuality, 3))]);
    } else if (hudUpscaleKind == 0) {
        snprintf(h.upscaler, sizeof h.upscaler, "MetalFX");
    }
    h.upscaleMs = hudUpscaleKind >= 0 ? hudUpscaleMs : 0;
    ScaleCtx *sc = atomic_load(&scaleCurrent);
    if (sc) {
        static const char *names[] = {"off", "LS1", "FSR", "BCAS", "Bicubic", "Nearest", "NIS"};
        snprintf(h.scaling, sizeof h.scaling, "%s%s %d\u00d7%d \u2192 %d\u00d7%d", names[MAX(0, MIN(sc->mode, 6))],
                 sc->mode == 1 && sc->perf ? " perf" : "", sc->inW, sc->inH, sc->outW, sc->outH);
    }
    task_vm_info_data_t vm;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS) h.memoryMB = vm.phys_footprint / 1048576.0;
    h.thermal = (int)NSProcessInfo.processInfo.thermalState;
    lsfgHudPublish(&h);
}

static void startStatsTimer(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        captureCheckRequest();
        NSMutableString *line = [NSMutableString string];
        long c[kCounterCount];
        for (int i = 0; i < kCounterCount; i++) {
            long n = c[i] = atomic_exchange(&counters[i], 0);
            if (n) [line appendFormat:@" %s=%ld", counterNames[i], n];
        }
        os_unfair_lock_lock(&pacingLock);
        const int hudShown = shownCount > 1 ? shownCount + 1 : shownCount, hudDropped = droppedCount;
        const double hudMean = shownCount ? shownSum / shownCount : 0, hudMax = shownMax;
        const double hudSd = shownCount ? sqrt(MAX(0, shownSumSq / shownCount - hudMean * hudMean)) : 0;
        if (shownCount > 1) {
            double mean = shownSum / shownCount, sd = sqrt(MAX(0, shownSumSq / shownCount - mean * mean));
            [line appendFormat:@" | on screen %d fps, interval %.1f ms ±%.1f, max %.1f, dropped %d",
                               shownCount + 1, mean, sd, shownMax, droppedCount];
        } else if (shownCount + droppedCount > 0) {
            [line appendFormat:@" | on screen %d, dropped %d", shownCount, droppedCount];
        }
        shownCount = droppedCount = 0; shownSum = shownSumSq = shownMax = 0;
        os_unfair_lock_unlock(&pacingLock);
        [line appendString:nssStatsLine()];
        if (line.length) lsfg_log(@"per second:%@", line);
        long fn = atomic_exchange(&frameGpuCount, 0), fu = atomic_exchange(&frameGpuUs, 0);
        long ln = atomic_exchange(&linkGpuCount, 0), lu = atomic_exchange(&linkGpuUs, 0);
        long qn = atomic_exchange(&queueAheadCount, 0), qu = atomic_exchange(&queueAheadUs, 0);
        long wu = atomic_exchange(&slotWaitUs, 0);
        os_unfair_lock_lock(&busyLock);
        double busy = busySeconds; busySeconds = 0;
        os_unfair_lock_unlock(&busyLock);
        if (fn) lsfg_log(@"timing: game waits %.1f ms/s for a slot, frame GPU %.2f ms (game's last pass + LSFG), "
                         @"present GPU %.2f ms, queued %.1f ms ahead, buffer %.1f ms, GPU busy %.0f%%", wu / 1000.0, fu / 1000.0 / fn,
                         ln ? lu / 1000.0 / ln : 0.0, qn ? qu / 1000.0 / qn : 0.0, adaptiveBuffer * 1000, busy * 100);
        else if (busy > 0) lsfg_log(@"timing: GPU busy %.0f%% (frame generation idle)", busy * 100);
        if (config.hud) {
            // The HUD's frame cost over the last second, per game frame.
            static LSFGHudTotals prev;
            LSFGHudTotals now;
            lsfgHudReadTotals(&now);
            const double frames = (double)(now.gameFrames - prev.gameFrames);
            if (frames > 0 && prev.gameFrames > 0) {
                const double up = now.upscaleMs - prev.upscaleMs, lsfg = now.lsfgMs - prev.lsfgMs;
                const long lf = now.lsfgFrames - prev.lsfgFrames, uf = now.upscaleFrames - prev.upscaleFrames;
                const long passes = now.displayPasses - prev.displayPasses;
                lsfg_log(@"frame cost: game %.2f ms, upscale %.2f ms, LSFG %.2f ms (%ld frames timed), display %.2f ms per game frame "
                         @"(%.3f ms a pass, %.2f passes a frame; mean %.3f ms)",
                         MAX(0, (now.gpuBusyMs - prev.gpuBusyMs - up - (now.lsfgInGameWork ? lsfg : 0)) / frames),
                         uf ? up / uf : 0.0, lf ? lsfg / lf : 0.0, lf,
                         now.displayPassMs > 0 ? now.displayPassMs * passes / frames : (now.displayMs - prev.displayMs) / frames,
                         now.displayPassMs, passes / frames, passes ? (now.displayMs - prev.displayMs) / passes : 0.0);
            }
            prev = now;
        }
        if (config.hud)
            publishHUD(c, hudShown, hudMean, hudSd, hudMax, hudDropped, fn ? fu / 1000.0 / fn : 0, ln ? lu / 1000.0 / ln : 0,
                       qn ? qu / 1000.0 / qn : 0, busy);
        reloadConfigIfChanged();
        readScreenRefresh();   // the window may move to another screen
        // Memory every 10 s, so leaks show up in the log (same number as Activity Monitor's "Memory").
        static int tick;
        if (++tick % 10 == 0) {
            task_vm_info_data_t vm;
            mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
            if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) == KERN_SUCCESS)
                lsfg_log(@"memory: footprint %llu MB, thermal state %ld", vm.phys_footprint >> 20,
                         (long)NSProcessInfo.processInfo.thermalState);
        }
    });
    dispatch_resume(timer);
}

#include "lsfg_nss_hook.m"

__attribute__((constructor)) static void lsfg_unix_init(void) {
    @autoreleasepool {
        Dl_info info = {0};
        dladdr((void *)lsfg_unix_init, &info);
        lsfg_log(@"lsfghook loaded in %@ (%@) from %s", NSProcessInfo.processInfo.processName,
                 NSProcessInfo.processInfo.arguments.firstObject ?: @"?", info.dli_fname ?: "?");
        const char *enable = getenv("LSFG_ENABLE");
        if (enable && enable[0] == '0') { lsfg_log(@"LSFG_ENABLE=0, no hooks installed"); return; }
        // LSFG_EXE_PATH: pretend to be this .exe (tests; under Wine the PE side sends the real path).
        if (getenv("LSFG_EXE_PATH")) exePath = @(getenv("LSFG_EXE_PATH"));
        loadConfig();
        // A Lossless.dll the user added in the app (a copy bought outside Steam) wins over the Steam install;
        // LSFG_DLL from the environment wins over both. The bridges read LSFG_DLL when they load the DLL.
        NSString *chosenDLL = [appDataDir() stringByAppendingPathComponent:@"lossless/Lossless.dll"];
        if (!getenv("LSFG_DLL") && [NSFileManager.defaultManager fileExistsAtPath:chosenDLL]) {
            setenv("LSFG_DLL", chosenDLL.fileSystemRepresentation, 1);
            lsfg_log(@"Lossless Scaling: the copy added in the app (%@)", chosenDLL);
        }
        // Loaded even when the profile has frame generation off, so it can be switched on live.
        fgAvailable = envOn("LSFG_READABLE", YES) && loadBridge();
        scaleAvailable = fgAvailable && loadScaleBridge();
        atomic_store(&fgOn, config.enabled);
        captured = [NSMutableSet set];
        lsfg_log(@"frame generation %s", !fgAvailable ? "unavailable" : config.enabled ? "on" : "off");
        installLayerHook();
        nssInstall();
        startStatsTimer();
        readScreenRefresh();
        dispatch_async(dispatch_get_main_queue(), ^{ captureInstallHotkey(); });   // once AppKit runs
    }
}

#pragma mark - Frame cap

// Seconds per frame for the cap, 0 when off. Auto: the display's refresh divided by the frames shown per real frame
// (frame generation's multiplier when it runs), so real frames arrive on an even cadence that the generated ones fill
// exactly; 4x on 60 Hz shows 2x, so the multiplier only counts as far as real frames stay at 30 fps or more.
static double frameCapInterval(void) {
    int cap = config.fpsCap;
    if (cap > 0) return 1.0 / cap;
    if (cap == 0) return 0;
    // The nominal rate, not the display link's measured one: that drifts (52-58 Hz on a 60 Hz screen while frames
    // are skipped), and below 60 only one real frame at 30 fps would fit, so the cap jumped to ~55 and back.
    double refresh = atomic_load(&screenRefresh);
    if (refresh <= 0) refresh = effectiveRefresh();
    if (refresh <= 0) return 0;
    if (NSProcessInfo.processInfo.lowPowerModeEnabled) refresh = MAX(refresh, 1.0 / 60);
    int shown = atomic_load(&fgOn) && fgAvailable && !lsfgMissing ? config.multiplier : 1;
    int fit = MAX(1, (int)floor(1.0 / refresh / 30 + 0.25));   // real frames at 30 fps or more
    return refresh * MIN(shown, fit);
}

// Called by the PE side on the game's own thread right after its swap chain's Present returns, so the wait sits
// between frames: the game reads input for its next frame after it, as with a game's own limiter. (Waiting in
// nextDrawable would run on D3DMetal's queue thread, after the game had already read input and simulated the
// frame, and back up D3DMetal's queue by a frame or more.) Keeps a steady cadence: a frame that comes in late by
// less than one interval doesn't move it, so the average holds; one later than that starts it afresh.
static long frameCapWait(void) {
    static double next, lastInterval;
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    double interval = frameCapInterval();
    if (fabs(interval - lastInterval) > 0.0002) {
        if (interval > 0) lsfg_log(@"frame cap %.1f fps%@ (waits after the game's Present)", 1 / interval, config.fpsCap < 0 ? @" (auto)" : @"");
        else if (lastInterval > 0) lsfg_log(@"frame cap off");
        lastInterval = interval;
        next = 0;
    }
    if (interval <= 0) return 0;
    double now = CACurrentMediaTime();
    if (next == 0 || now - next > interval) { next = now + interval; return 0; }
    if (now < next) mach_wait_until((uint64_t)(next * 1e9 * timebase.denom / timebase.numer));
    next += interval;
    return 0;
}

#pragma mark - Wine unixlib entry points

typedef long NTSTATUS;
static NTSTATUS lsfg_ping(void *args) {
    *(uint32_t *)args = 0x4C534647; // 'LSFG'
    return 0;
}
// The PE side sends the running .exe's Unix path once it loads; settings can now come from the
// game folder's .lsfg/profile.json.
static NTSTATUS lsfg_set_exe(void *args) {
    const char *path = *(const char **)args;
    if (!path || exePath) return 0;
    @autoreleasepool {
        exePath = [NSString stringWithUTF8String:path];
        lsfg_log(@"running %@", exePath);
        applyConfigChanges();
    }
    return 0;
}
// The PE side's Present hook: wait for the frame cap.
static NTSTATUS lsfg_frame_wait(void *args) {
    (void)args;
    return frameCapWait();
}
// A message from the PE side for the log.
static NTSTATUS lsfg_pe_log(void *args) {
    const char *message = *(const char **)args;
    if (message) @autoreleasepool { lsfg_log(@"%s", message); }
    return 0;
}
__attribute__((visibility("default"))) const void *__wine_unix_call_funcs[] = {
    (const void *)lsfg_ping, (const void *)lsfg_set_exe, (const void *)lsfg_frame_wait, (const void *)lsfg_pe_log,
};
