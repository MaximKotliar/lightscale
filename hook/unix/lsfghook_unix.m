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
// Settings come from the game's profile in ~/Library/Application Support/lsfg-metal/profiles.json
// (written by LSFG Metal.app): {"default": {...}, "games": {"witcher3.exe": {...}}} with keys
// enabled, performance, flowScale, bufferMs. Environment variables override them:
//   LSFG_ENABLE=0        load but install no hooks
//   LSFG_FG=0            observe only, no frame generation (default: on)
//   LSFG_FLOW_SCALE=F    motion-estimation resolution, 0.25-1.0 (default 1.0)
//   LSFG_PERFORMANCE=0   use LSFG quality mode (default: performance mode)
//   LSFG_READABLE=0      leave framebufferOnly alone (disables frame generation)
//   LSFG_MULTIPLIER=N    2 (default), 3 or 4 frames shown per real frame
//   LSFG_BUFFER_MS=N     scheduling headroom that absorbs frame-time jitter (default 8 ms)
//   LSFG_LOG=path        log file (default ~/Library/Logs/lsfg-metal.log)

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <sys/stat.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>
#import <math.h>
#import <stdatomic.h>

#pragma mark - Logging

static void lsfg_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void lsfg_log(NSString *fmt, ...) {
    static dispatch_once_t once;
    static FILE *file;
    dispatch_once(&once, ^{
        const char *path = getenv("LSFG_LOG");
        NSString *p = path ? @(path) : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/lsfg-metal.log"];
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
    kMTL4Signal, kMTL4Wait, kNextDrawable, kGenerated, kLinkUpdates, kSkipped, kCounterCount
} Counter;
static const char *counterNames[kCounterCount] = {
    "drawable.present", "drawable.presentAtTime", "drawable.presentAfterMinimumDuration",
    "cmdbuf.presentDrawable", "cmdbuf.presentDrawable:atTime", "cmdbuf.presentDrawable:afterMinimumDuration",
    "mtl4queue.signalDrawable", "mtl4queue.waitForDrawable", "layer.nextDrawable", "generated", "link.updates", "queue.flushed",
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
static double busyEnd, busySeconds;
static void addGpuSpan(CFTimeInterval start, CFTimeInterval end) {
    if (end <= start) return;
    os_unfair_lock_lock(&busyLock);
    if (end > busyEnd) { busySeconds += end - MAX(start, busyEnd); busyEnd = end; }
    os_unfair_lock_unlock(&busyLock);
}
static _Atomic long slotWaitUs, frameGpuUs, frameGpuCount, linkGpuUs, linkGpuCount, queueAheadUs, queueAheadCount;

enum { kSlots = 4 };
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
            }
            lastShown = t;
        }
        os_unfair_lock_unlock(&pacingLock);
    }];
}

// The effective settings for this game: defaults, then profiles.json, then environment.
static struct { BOOL enabled, performance; int multiplier; float flowScale, bufferMs; } config = { YES, YES, 2, 1.0f, 8.0f };

static void applyProfile(NSDictionary *p) {
    if (![p isKindOfClass:NSDictionary.class]) return;
    if ([p[@"enabled"] isKindOfClass:NSNumber.class]) config.enabled = [p[@"enabled"] boolValue];
    if ([p[@"performance"] isKindOfClass:NSNumber.class]) config.performance = [p[@"performance"] boolValue];
    if ([p[@"flowScale"] isKindOfClass:NSNumber.class]) config.flowScale = [p[@"flowScale"] floatValue];
    if ([p[@"bufferMs"] isKindOfClass:NSNumber.class]) config.bufferMs = [p[@"bufferMs"] floatValue];
    if ([p[@"multiplier"] isKindOfClass:NSNumber.class]) config.multiplier = [p[@"multiplier"] intValue];
}

static void loadConfig(void) {
    config.enabled = YES; config.performance = YES; config.multiplier = 2;
    config.flowScale = 1.0f; config.bufferMs = 8.0f;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/lsfg-metal/profiles.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *exe = NSProcessInfo.processInfo.processName.lowercaseString;
    if ([root isKindOfClass:NSDictionary.class]) {
        applyProfile(root[@"default"]);
        NSDictionary *games = root[@"games"];
        if ([games isKindOfClass:NSDictionary.class]) applyProfile(games[exe]);
    }
    // Environment variables (e.g. in the bottle's cxbottle.conf) win over profiles.json, so say so:
    // they also pin those settings against live changes from the app.
    static dispatch_once_t warned;
    dispatch_once(&warned, ^{
        NSMutableArray *set = [NSMutableArray array];
        for (NSString *name in @[@"LSFG_FG", @"LSFG_PERFORMANCE", @"LSFG_FLOW_SCALE", @"LSFG_BUFFER_MS", @"LSFG_MULTIPLIER"])
            if (getenv(name.UTF8String)) [set addObject:name];
        if (set.count) lsfg_log(@"environment overrides the profile (the app can't change these): %@", [set componentsJoinedByString:@", "]);
    });
    const char *v;
    if ((v = getenv("LSFG_FG"))) config.enabled = v[0] != '0';
    if ((v = getenv("LSFG_PERFORMANCE"))) config.performance = v[0] != '0';
    if ((v = getenv("LSFG_FLOW_SCALE"))) config.flowScale = (float)atof(v);
    if ((v = getenv("LSFG_BUFFER_MS"))) config.bufferMs = (float)atof(v);
    if ((v = getenv("LSFG_MULTIPLIER"))) config.multiplier = atoi(v);
    config.multiplier = MAX(2, MIN(config.multiplier, kMaxGenerated + 1));
    config.flowScale = fminf(fmaxf(config.flowScale, 0.25f), 1.0f);
    config.bufferMs = fminf(fmaxf(config.bufferMs, 0.0f), 50.0f);
    lsfg_log(@"profile for %@: frame generation %s %dx, %s mode, flow %.2f, buffer %.0f ms", exe, config.enabled ? "on" : "off", config.multiplier,
             config.performance ? "performance" : "quality", config.flowScale, config.bufferMs);
}

static void fgRebuild(void);
static void setOverlayHidden(BOOL hidden);

// The app saves profiles.json on every change; pick changes up while the game runs (checked
// once a second). On/off and the pacing buffer apply at once; the rest rebuilds the context.
static void reloadConfigIfChanged(void) {
    static struct timespec seen;
    struct stat st;
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/lsfg-metal/profiles.json"];
    if (stat(path.fileSystemRepresentation, &st) != 0) return;
    BOOL first = seen.tv_sec == 0;
    if (!first && st.st_mtimespec.tv_sec == seen.tv_sec && st.st_mtimespec.tv_nsec == seen.tv_nsec) return;
    seen = st.st_mtimespec;
    if (first) return; // read at startup already
    typeof(config) before = config;
    loadConfig();
    if (config.enabled != before.enabled) {
        atomic_store(&fgOn, config.enabled);
        lsfg_log(@"frame generation switched %s", config.enabled ? "on" : "off");
    }
    if (config.multiplier != before.multiplier || config.performance != before.performance || config.flowScale != before.flowScale)
        fgRebuild();
}

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
            lsfg_log(@"frame generation off: %s", error);
            atomic_store(&fgState, -1);
            return;
        }
        fgDevice = device;
        allocateRings(device, w, h, format, config.multiplier);
        presentQueue = [device newCommandQueue];
        presenter = dispatch_queue_create("lsfg.presenter", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
        slotsFree = dispatch_semaphore_create(kSlots);
        fgContext = ctx;
        fgWidth = w; fgHeight = h; fgFormat = format;
        atomic_store(&fgState, 2);
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
        if (atomic_load(&fgState) != 2 || !device) return;
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

// Puts our overlay layer on top of the game's layer (main thread; ready a moment later).
static void attachOverlay(CAMetalLayer *game) {
    int expected = 0;
    if (!game || !atomic_compare_exchange_strong(&overlayState, &expected, 1)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        CAMetalLayer *o = [CAMetalLayer layer];
        o.device = game.device;
        o.pixelFormat = game.pixelFormat;
        o.colorspace = game.colorspace;
        o.wantsExtendedDynamicRangeContent = game.wantsExtendedDynamicRangeContent;
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
        lsfg_log(@"overlay attached: %.0fx%.0f on %@", o.drawableSize.width, o.drawableSize.height, NSStringFromClass([game class]));
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

// Display times follow a steady cadence: each frame continues from the previous real frame's
// target, so the game's frame-time jitter doesn't reach the screen. The cadence only snaps to
// "now" when frames arrive too late, and never runs far ahead (bounded latency).
static CFTimeInterval lastRealTarget;
static void presentSlot(int slot, int generated, CFTimeInterval completedAt) {
    CFTimeInterval period = MIN(frameInterval > 0 ? frameInterval : 1.0 / 30, 0.1);
    // Show only as many frames per real frame as the display can: Low Power Mode caps ProMotion
    // displays at 60 Hz while still reporting (and ticking the display link at) 120. Pick the
    // generated frames evenly, e.g. 4x at 30 fps on 60 Hz shows the middle one: a clean 2x.
    double refresh = MAX(atomic_load(&linkInterval), NSProcessInfo.processInfo.lowPowerModeEnabled ? 1.0 / 60 : 0);
    int fit = refresh > 0 ? MAX(1, (int)llround(period / refresh)) : generated + 1;
    int shown = MIN(generated + 1, fit);
    int picks[kMaxGenerated + 1];
    for (int k = 1; k < shown; k++) picks[k - 1] = (int)llround((double)k * (generated + 1) / shown) - 1;
    picks[shown - 1] = -1; // the real frame
    CFTimeInterval step = period / shown;
    double buffer = config.bufferMs / 1000.0; // read every frame: changes apply live
    // Earliest a new frame can appear: the refresh after the link's latest one.
    double target = atomic_load(&linkTarget);
    CFTimeInterval earliest = target > 0 ? target + (refresh > 0 ? refresh : 1.0 / 120) : CACurrentMediaTime() + 0.003;
    CFTimeInterval first = lastRealTarget > 0 ? lastRealTarget + step : earliest;
    if (first < earliest) first = earliest + buffer;                       // fell behind: restart the cadence
    if (first > earliest + buffer + period / 2) first = earliest + buffer; // drifted ahead: pull latency back in
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
    id<MTLCommandBuffer> cb = [presentQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:show.index < 0 ? realRing[show.slot] : genRing[show.slot][show.index] toTexture:drawable.texture];
    [blit endEncoding];
    trackPresented(drawable);
    [cb presentDrawable:drawable];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        os_unfair_lock_lock(&queueLock);
        releaseFrameLocked(show);
        os_unfair_lock_unlock(&queueLock);
    }];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.GPUEndTime > done.GPUStartTime) {
            atomic_fetch_add(&linkGpuUs, (long)((done.GPUEndTime - done.GPUStartTime) * 1e6));
            atomic_fetch_add(&linkGpuCount, 1);
        }
    }];
    // Back on after being switched off: reveal the overlay once it holds a fresh frame.
    if (atomic_load(&overlayHidden) && atomic_load(&fgOn))
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) { if (atomic_load(&fgOn)) setOverlayHidden(NO); }];
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
static void fgEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    if (!atomic_load(&fgOn)) {
        // Switched off: the game presents its own frames again; prime LSFG afresh when back on.
        if (atomic_load(&overlayState) == 2) setOverlayHidden(YES);
        fgWarmup = 1;
        return;
    }
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

    // Feed LSFG every real frame (this also warms up its history before the overlay is up).
    id<MTLTexture> input = (__bridge id<MTLTexture>)bridge.input(fgContext);
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target toTexture:input];
    [blit endEncoding];
    int generated = bridge.encode(fgContext, (__bridge const void *)cb);
    if (ov != 2) return; // the game keeps presenting itself until the overlay is ready
    // A fresh context (or frame generation just switched back on) has no history yet: its first
    // frame only primes it, and the game presents that one itself.
    if (fgWarmup > 0) { fgWarmup--; return; }

    // A slot frees up when the display has shown (or skipped) its frames. If the display link
    // slows down (window covered, minimized), never stall the game: after 4 ms, drop frames that
    // haven't been shown yet to free their slots.
    CFTimeInterval waitStart = CACurrentMediaTime();
    if (dispatch_semaphore_wait(slotsFree, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_MSEC)) != 0) {
        os_unfair_lock_lock(&queueLock);
        while (queueCount > 0) {
            releaseFrameLocked(frameQueue[queueHead]);
            queueHead = (queueHead + 1) % kQueueCapacity;
            queueCount--;
        }
        os_unfair_lock_unlock(&queueLock);
        bump(kSkipped);
        // Frames still being copied to the screen release their slot within a refresh.
        dispatch_semaphore_wait(slotsFree, DISPATCH_TIME_FOREVER);
    }
    atomic_fetch_add(&slotWaitUs, (long)((CACurrentMediaTime() - waitStart) * 1e6));
    int slot = nextSlot++ % kSlots;
    blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target toTexture:realRing[slot]];
    generated = MAX(0, MIN(generated, kMaxGenerated));
    while (generated > 0 && !genRing[slot][generated - 1]) generated--;
    for (int j = 0; j < generated; j++)
        [blit copyFromTexture:(__bridge id<MTLTexture>)bridge.output(fgContext, j) toTexture:genRing[slot][j]];
    [blit endEncoding];
    os_unfair_lock_lock(&capturedLock);
    [captured addObject:@((uintptr_t)(__bridge void *)target)];
    os_unfair_lock_unlock(&capturedLock);

    int count = MAX(0, MIN(generated, kMaxGenerated));
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
                if (conforms(object_getClass(d), drawable)) describeDrawable(d, "mtl4queue.signalDrawable");
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
                    fgEncode(self, target);
                }
                // Every command buffer the game commits counts toward GPU busy time (ours don't).
                if ([(id<MTLCommandBuffer>)self commandQueue] != presentQueue)
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
    // MTL4 command buffers take an MTL4RenderPassDescriptor (same colorAttachments shape).
    hookAll(@selector(renderCommandEncoderWithDescriptor:), ^BOOL(Class c) { return conforms(c, @protocol(MTL4CommandBuffer)); }, ^id(IMP orig) {
        return ^id(id self, id desc) {
            id enc = ((id (*)(id, SEL, id))orig)(self, @selector(renderCommandEncoderWithDescriptor:), desc);
            if (diagActive()) @autoreleasepool {
                id target = [[[desc valueForKey:@"colorAttachments"] objectAtIndexedSubscript:0] valueForKey:@"texture"];
                if (isDrawableTexture(target))
                    lsfg_log(@"diag MTL4 render pass into drawable: cb %@ on %@", NSStringFromClass([self class]), threadName());
            }
            return enc;
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

static void startStatsTimer(void) {
    static dispatch_source_t timer;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        NSMutableString *line = [NSMutableString string];
        for (int i = 0; i < kCounterCount; i++) {
            long n = atomic_exchange(&counters[i], 0);
            if (n) [line appendFormat:@" %s=%ld", counterNames[i], n];
        }
        os_unfair_lock_lock(&pacingLock);
        if (shownCount > 1) {
            double mean = shownSum / shownCount, sd = sqrt(MAX(0, shownSumSq / shownCount - mean * mean));
            [line appendFormat:@" | on screen %d fps, interval %.1f ms ±%.1f, max %.1f, dropped %d",
                               shownCount + 1, mean, sd, shownMax, droppedCount];
        } else if (shownCount + droppedCount > 0) {
            [line appendFormat:@" | on screen %d, dropped %d", shownCount, droppedCount];
        }
        shownCount = droppedCount = 0; shownSum = shownSumSq = shownMax = 0;
        os_unfair_lock_unlock(&pacingLock);
        if (line.length) lsfg_log(@"per second:%@", line);
        long fn = atomic_exchange(&frameGpuCount, 0), fu = atomic_exchange(&frameGpuUs, 0);
        long ln = atomic_exchange(&linkGpuCount, 0), lu = atomic_exchange(&linkGpuUs, 0);
        long qn = atomic_exchange(&queueAheadCount, 0), qu = atomic_exchange(&queueAheadUs, 0);
        long wu = atomic_exchange(&slotWaitUs, 0);
        os_unfair_lock_lock(&busyLock);
        double busy = busySeconds; busySeconds = 0;
        os_unfair_lock_unlock(&busyLock);
        if (fn) lsfg_log(@"timing: game waits %.1f ms/s for a slot, frame GPU %.2f ms (game's last pass + LSFG), "
                         @"present GPU %.2f ms, queued %.1f ms ahead, GPU busy %.0f%%", wu / 1000.0, fu / 1000.0 / fn,
                         ln ? lu / 1000.0 / ln : 0.0, qn ? qu / 1000.0 / qn : 0.0, busy * 100);
        else if (busy > 0) lsfg_log(@"timing: GPU busy %.0f%% (frame generation idle)", busy * 100);
        reloadConfigIfChanged();
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

__attribute__((constructor)) static void lsfg_unix_init(void) {
    @autoreleasepool {
        Dl_info info = {0};
        dladdr((void *)lsfg_unix_init, &info);
        lsfg_log(@"lsfghook loaded in %@ (%@) from %s", NSProcessInfo.processInfo.processName,
                 NSProcessInfo.processInfo.arguments.firstObject ?: @"?", info.dli_fname ?: "?");
        const char *enable = getenv("LSFG_ENABLE");
        if (enable && enable[0] == '0') { lsfg_log(@"LSFG_ENABLE=0, no hooks installed"); return; }
        loadConfig();
        // Loaded even when the profile has frame generation off, so it can be switched on live.
        fgAvailable = envOn("LSFG_READABLE", YES) && loadBridge();
        atomic_store(&fgOn, config.enabled);
        captured = [NSMutableSet set];
        lsfg_log(@"frame generation %s", !fgAvailable ? "unavailable" : config.enabled ? "on" : "off");
        installLayerHook();
        startStatsTimer();
    }
}

#pragma mark - Wine unixlib entry points

typedef long NTSTATUS;
static NTSTATUS lsfg_ping(void *args) {
    *(uint32_t *)args = 0x4C534647; // 'LSFG'
    return 0;
}
__attribute__((visibility("default"))) const void *__wine_unix_call_funcs[] = { (const void *)lsfg_ping };
