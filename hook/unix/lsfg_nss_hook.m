// NSS upscaling in place of MetalFX's temporal upscaler.
//
// D3DMetal turns a game's DLSS calls into MetalFX temporal upscaling. When a game's profile picks
// "upscaler": "nss", the hook catches -[<MetalFX temporal scaler> encodeToCommandBuffer:] and encodes
// NSSMetal's upscaler (vendor/nss-metal) into the same command buffer instead, with the inputs the game
// handed MetalFX. Also times every upscale call, MetalFX's or NSS's, for the per-second log line.
//
// Included by lsfghook_unix.m (uses lsfg_log, config and appDataDir).

#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#import "NSSMetal/NSSMetal.h"

#pragma mark - MetalFX interception

static const void *kNssKey = &kNssKey;
static atomic_int nssLogged;

// Per scaler: our upscaler (rebuilt when the quality setting or size changes).
@interface NssScalerState : NSObject {
@public
    NSSUpscaler *up;
    int quality;
    BOOL failed, loggedFallback;
    uint64_t frames;
    int lastW, lastH, sizeChanges, rebuilds;
    CFTimeInterval firstRebuild;
}
@end
@implementation NssScalerState
@end

static float envFloat(const char *name, float fallback) {
    const char *v = getenv(name);
    return v ? (float)atof(v) : fallback;
}

static void nssDescribe(id<MTLFXTemporalScalerBase> s, id cb, const char *what) {
    lsfg_log(@"nss: %s scaler %s %lux%lu -> %lux%lu, content %lux%lu, color %lu %@ %lux%lu, depth %lu %@, motion %lu %@ %lux%lu, "
             "output %lu %@ usage 0x%lx, exposure %@, preExposure %.3f, jitter %.3f %.3f, mv scale %.3f %.3f, depth reversed %d, reset %d, cb %s",
             what, class_getName(object_getClass(s)), (unsigned long)s.inputWidth, (unsigned long)s.inputHeight,
             (unsigned long)s.outputWidth, (unsigned long)s.outputHeight,
             (unsigned long)s.inputContentWidth, (unsigned long)s.inputContentHeight,
             (unsigned long)s.colorTexture.pixelFormat, s.colorTexture ? @"" : @"(none)", (unsigned long)s.colorTexture.width, (unsigned long)s.colorTexture.height,
             (unsigned long)s.depthTexture.pixelFormat, s.depthTexture ? @"" : @"(none)",
             (unsigned long)s.motionTexture.pixelFormat, s.motionTexture ? @"" : @"(none)", (unsigned long)s.motionTexture.width, (unsigned long)s.motionTexture.height,
             (unsigned long)s.outputTexture.pixelFormat, s.outputTexture ? @"" : @"(none)", (unsigned long)s.outputTexture.usage,
             s.exposureTexture ? [NSString stringWithFormat:@"%lux%lu fmt %lu", (unsigned long)s.exposureTexture.width, (unsigned long)s.exposureTexture.height, (unsigned long)s.exposureTexture.pixelFormat] : @"none",
             s.preExposure, s.jitterOffsetX, s.jitterOffsetY, s.motionVectorScaleX, s.motionVectorScaleY, s.isDepthReversed, s.reset,
             cb ? class_getName(object_getClass(cb)) : "?");
}

// Returns YES when NSS handled the frame.
static BOOL nssTry(id<MTLFXTemporalScalerBase> s, id cbObj) {
    NssScalerState *st = objc_getAssociatedObject(s, kNssKey);
    if (!st) {
        st = [NssScalerState new];
        objc_setAssociatedObject(s, kNssKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The render size the game actually uses (DLSS mode, dynamic resolution), whichever upscaler runs.
    const int cw = (int)(s.inputContentWidth ?: s.inputWidth), ch = (int)(s.inputContentHeight ?: s.inputHeight);
    if (cw != st->lastW || ch != st->lastH) {
        if (st->sizeChanges++ < 20)
            lsfg_log(@"nss: scaler %p renders %dx%d -> %lux%lu (%.2fx)%s", (__bridge void *)s, cw, ch, (unsigned long)s.outputWidth,
                     (unsigned long)s.outputHeight, ch ? (double)s.outputHeight / ch : 0.0, st->sizeChanges == 20 ? " (further changes not logged)" : "");
        st->lastW = cw, st->lastH = ch;
    }
    if (config.upscaler != 1) return NO;
    if (st->failed) return NO;
    BOOL metal4 = NO;
    if (@available(macOS 26.0, *)) metal4 = [cbObj conformsToProtocol:@protocol(MTL4CommandBuffer)];
    if (!metal4 && ![cbObj conformsToProtocol:@protocol(MTLCommandBuffer)]) {
        if (!st->loggedFallback) lsfg_log(@"nss: %s is not a command buffer we know; MetalFX runs instead", class_getName(object_getClass(cbObj)));
        st->loggedFallback = YES;
        return NO;
    }
    id<MTLDevice> device = [(id<MTLCommandBuffer>)cbObj device];
    const int wr = (int)(s.inputContentWidth ?: s.inputWidth), hr = (int)(s.inputContentHeight ?: s.inputHeight);
    const int wo = (int)s.outputWidth, ho = (int)s.outputHeight;
    if (!s.colorTexture || !s.depthTexture || !s.motionTexture || !s.outputTexture || wo <= wr || ho <= hr ||
        !(s.outputTexture.usage & MTLTextureUsageShaderWrite) || s.motionTexture.width != s.colorTexture.width) {
        if (!st->loggedFallback) { nssDescribe(s, cbObj, "unsupported"); lsfg_log(@"nss: unsupported inputs; MetalFX runs instead"); }
        st->loggedFallback = YES;
        return NO;
    }
    const int quality = config.nssQuality;
    NSSUpscaler *up = st->up;
    if (!up || st->quality != quality || (int)up.inputWidth != wr || (int)up.inputHeight != hr || (int)up.outputWidth != wo ||
        (int)up.outputHeight != ho) {
        // Dynamic resolution would rebuild every few frames (a stall each time): hand those scalers back to MetalFX.
        const CFTimeInterval now = CACurrentMediaTime();
        if (now - st->firstRebuild > 10) st->firstRebuild = now, st->rebuilds = 0;
        if (++st->rebuilds > 4) {
            st->failed = YES;
            lsfg_log(@"nss: the render size keeps changing (dynamic resolution?); MetalFX runs for this scaler");
            return NO;
        }
        CFTimeInterval t0 = CACurrentMediaTime();
        NSSUpscalerDescriptor *d = [NSSUpscalerDescriptor new];
        d.inputWidth = wr, d.inputHeight = hr, d.outputWidth = wo, d.outputHeight = ho, d.quality = (NSSQuality)quality;
        // weights and kernels: the app's folder, or LSFG_NSS_DIR (tests: freshly built kernels)
        const char *dir = getenv("LSFG_NSS_DIR");
        d.resourceDirectory = [NSURL fileURLWithPath:dir ? @(dir) : [appDataDir() stringByAppendingPathComponent:@"nss"]];
        d.zNear = envFloat("LSFG_NSS_NEAR", 0.1f), d.zFar = envFloat("LSFG_NSS_FAR", 1000.f), d.verticalFieldOfView = envFloat("LSFG_NSS_FOV", 1.0f);
        NSError *err = nil;
        up = st->up = [[NSSUpscaler alloc] initWithDevice:device descriptor:d error:&err];
        st->quality = quality;
        if (!up) { st->failed = YES; lsfg_log(@"nss: setup failed (%@); MetalFX runs instead", err.localizedDescription); return NO; }
        lsfg_log(@"nss: %s quality, %dx%d -> %dx%d, network input %lux%lu, set up in %.0f ms",
                 quality == 0 ? "low" : quality == 1 ? "mid" : "high", wr, hr, wo, ho, (unsigned long)up.networkWidth,
                 (unsigned long)up.networkHeight, (CACurrentMediaTime() - t0) * 1e3);
    }
    // Same conventions as MetalFX; LSFG_NSS_JSIGN / _MVSIGN = -1 flip them, for games that differ.
    const float jSign = envFloat("LSFG_NSS_JSIGN", 1.0f), mvSign = envFloat("LSFG_NSS_MVSIGN", 1.0f);
    up.colorTexture = s.colorTexture, up.depthTexture = s.depthTexture, up.motionTexture = s.motionTexture;
    up.exposureTexture = s.exposureTexture, up.outputTexture = s.outputTexture;
    up.jitterOffsetX = jSign * s.jitterOffsetX, up.jitterOffsetY = jSign * s.jitterOffsetY;
    up.motionVectorScaleX = mvSign * s.motionVectorScaleX, up.motionVectorScaleY = mvSign * s.motionVectorScaleY;
    up.depthReversed = s.isDepthReversed, up.reset = s.reset, up.preExposure = s.preExposure;
    if (atomic_fetch_add(&nssLogged, 1) < 3) nssDescribe(s, cbObj, metal4 ? "frame (Metal 4)" : "frame");
    if (metal4) {
        if (@available(macOS 26.0, *)) [up encodeToMTL4CommandBuffer:cbObj fence:s.fence];
    } else {
        [up encodeToCommandBuffer:cbObj];
    }
    up.colorTexture = up.depthTexture = up.motionTexture = up.exposureTexture = up.outputTexture = nil;   // don't keep the game's textures alive
    st->frames++;
    return YES;
}

#pragma mark - Upscale GPU time

// GPU time of each upscale, MetalFX or NSS alike: Metal 4 command-buffer timestamps just before and just after the
// call (a timestamp is taken once all earlier work in the command buffer has finished). Read back 16 frames later
// from a 32-frame ring; the per-second log line gets the median and p95 per upscaler.
enum { kTsFrames = 32, kTsDelay = 16 };
static os_unfair_lock tsLock = OS_UNFAIR_LOCK_INIT;
static id tsHeap;   // id<MTL4CounterHeap>
static double tsTicksPerMs;
static uint64_t tsFrame;
static int tsKind[kTsFrames];               // 0 MetalFX, 1 NSS
static NSMutableArray<NSNumber *> *tsSamples[2];
static atomic_long nssFramesThisSecond;
static NSMutableArray<NSNumber *> *tsCpu[2];   // CPU ms per upscale call on the render thread: 0 MetalFX, 1 NSS

static void tsCollect(int slot) {
    if (@available(macOS 26.0, *)) {
        NSData *d = [(id<MTL4CounterHeap>)tsHeap resolveCounterRange:NSMakeRange(2 * slot, 2)];
        if (d.length < 2 * sizeof(MTL4TimestampHeapEntry)) return;
        const MTL4TimestampHeapEntry *t = d.bytes;
        if (!t[0].timestamp || t[1].timestamp <= t[0].timestamp) return;
        const double ms = (double)(t[1].timestamp - t[0].timestamp) / tsTicksPerMs;
        if (ms > 0 && ms < 100) [tsSamples[tsKind[slot]] addObject:@(ms)];
        [(id<MTL4CounterHeap>)tsHeap invalidateCounterRange:NSMakeRange(2 * slot, 2)];
    }
}

// Wraps one upscale call. Returns the slot to close with tsAfter, or -1 (no timing for this command buffer).
static int tsBefore(id cbObj) {
    if (@available(macOS 26.0, *)) {
        if (![cbObj conformsToProtocol:@protocol(MTL4CommandBuffer)]) return -1;
        id<MTL4CommandBuffer> cb = cbObj;
        os_unfair_lock_lock(&tsLock);
        if (!tsHeap) {
            id<MTLDevice> dev = cb.device;
            MTL4CounterHeapDescriptor *hd = [MTL4CounterHeapDescriptor new];
            hd.type = MTL4CounterHeapTypeTimestamp, hd.count = 2 * kTsFrames;
            tsHeap = [dev newCounterHeapWithDescriptor:hd error:nil];
            tsTicksPerMs = (double)[dev queryTimestampFrequency] / 1000.0;
            tsSamples[0] = [NSMutableArray array], tsSamples[1] = [NSMutableArray array];
            lsfg_log(@"nss: timing upscales with GPU timestamps (%.0f MHz)", tsTicksPerMs / 1000.0);
        }
        const int slot = (int)(tsFrame % kTsFrames);
        if (tsFrame >= kTsDelay) tsCollect((int)((tsFrame - kTsDelay) % kTsFrames));
        tsFrame++;
        os_unfair_lock_unlock(&tsLock);
        if (!tsHeap) return -1;
        [cb writeTimestampIntoHeap:tsHeap atIndex:2 * slot];
        return slot;
    }
    return -1;
}
static void tsAfter(id cbObj, int slot, BOOL nss) {
    if (slot < 0) return;
    if (@available(macOS 26.0, *)) {
        tsKind[slot] = nss ? 1 : 0;
        [(id<MTL4CommandBuffer>)cbObj writeTimestampIntoHeap:tsHeap atIndex:2 * slot + 1];
    }
}

// " | upscale GPU NSS mid 2.31 ms (p95 2.60, 60 frames)" for the per-second log line; resets the window.
static NSString *nssStatsLine(void) {
    NSMutableString *out = [NSMutableString string];
    os_unfair_lock_lock(&tsLock);
    for (int k = 0; k < 2; k++) {
        NSMutableArray<NSNumber *> *v = tsSamples[k];
        if (!v.count) continue;
        [v sortUsingSelector:@selector(compare:)];
        const double med = v[v.count / 2].doubleValue, p95 = v[MIN(v.count - 1, (NSUInteger)(v.count * 0.95))].doubleValue;
        const char *q = config.nssQuality == 0 ? "low" : config.nssQuality == 2 ? "high" : "mid";
        [out appendFormat:@" | upscale GPU %s%s%s %.2f ms (p95 %.2f, %lu frames)", k ? "NSS" : "MetalFX", k ? " " : "", k ? q : "",
                          med, p95, (unsigned long)v.count];
        [v removeAllObjects];
    }
    for (int k = 0; k < 2; k++) {
        NSMutableArray<NSNumber *> *v = tsCpu[k];
        if (!v.count) continue;
        [v sortUsingSelector:@selector(compare:)];
        [out appendFormat:@", %s CPU %.3f ms (p95 %.3f)", k ? "NSS" : "MetalFX", v[v.count / 2].doubleValue,
                          v[MIN(v.count - 1, (NSUInteger)(v.count * 0.95))].doubleValue];
        [v removeAllObjects];
    }
    os_unfair_lock_unlock(&tsLock);
    const long n = atomic_exchange(&nssFramesThisSecond, 0);
    if (n && !out.length) [out appendFormat:@" | NSS upscaled %ld frames", n];
    return out;
}

static void nssHookScalerClass(Class cls) {
    static NSMutableSet *done;
    @synchronized(NSNull.null) {
        if (!done) done = [NSMutableSet set];
        NSString *name = @(class_getName(cls));
        if ([done containsObject:name]) return;
        [done addObject:name];
    }
    SEL sel = @selector(encodeToCommandBuffer:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { lsfg_log(@"nss: %s has no encodeToCommandBuffer:", class_getName(cls)); return; }
    IMP orig = method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, id cb) {
        const int slot = tsBefore(cb);
        BOOL nss;
        const CFTimeInterval c0 = CACurrentMediaTime();
        @autoreleasepool {
            nss = nssTry(self, cb);
        }
        if (nss) atomic_fetch_add(&nssFramesThisSecond, 1);
        else ((void (*)(id, SEL, id))orig)(self, sel, cb);
        // CPU time of the whole upscale call (NSS, or the decision to pass on plus MetalFX's own encode)
        const double cpuMs = (CACurrentMediaTime() - c0) * 1e3;
        os_unfair_lock_lock(&tsLock);
        if (!tsCpu[nss]) tsCpu[nss] = [NSMutableArray array];
        [tsCpu[nss] addObject:@(cpuMs)];
        os_unfair_lock_unlock(&tsLock);
        tsAfter(cb, slot, nss);
    }));
    lsfg_log(@"nss: hooked -[%s encodeToCommandBuffer:]", class_getName(cls));
}

// The temporal scaler classes are private; catch them where they're made.
static void nssInstall(void) {
    [NSSUpscaler setLogHandler:^(NSString *m) { lsfg_log(@"%@", m); }];
    Class d = objc_getClass("MTLFXTemporalScalerDescriptor");
    if (!d) { lsfg_log(@"nss: MetalFX not available"); return; }
    SEL s1 = @selector(newTemporalScalerWithDevice:);
    Method m1 = class_getInstanceMethod(d, s1);
    if (m1) {
        IMP o1 = method_getImplementation(m1);
        method_setImplementation(m1, imp_implementationWithBlock(^id(MTLFXTemporalScalerDescriptor *self, id dev) {
            id sc = ((id (*)(id, SEL, id))o1)(self, s1, dev);
            lsfg_log(@"nss: game made a MetalFX temporal scaler (Metal 3) %lux%lu -> %lux%lu, color %lu depth %lu motion %lu output %lu, auto exposure %d, content properties %d",
                     (unsigned long)self.inputWidth, (unsigned long)self.inputHeight, (unsigned long)self.outputWidth, (unsigned long)self.outputHeight,
                     (unsigned long)self.colorTextureFormat, (unsigned long)self.depthTextureFormat, (unsigned long)self.motionTextureFormat,
                     (unsigned long)self.outputTextureFormat, self.isAutoExposureEnabled, self.isInputContentPropertiesEnabled);
            if (sc) nssHookScalerClass(object_getClass(sc));
            return sc;
        }));
    }
    SEL s2 = NSSelectorFromString(@"newTemporalScalerWithDevice:compiler:");
    Method m2 = class_getInstanceMethod(d, s2);
    if (m2) {
        IMP o2 = method_getImplementation(m2);
        method_setImplementation(m2, imp_implementationWithBlock(^id(MTLFXTemporalScalerDescriptor *self, id dev, id compiler) {
            id sc = ((id (*)(id, SEL, id, id))o2)(self, s2, dev, compiler);
            lsfg_log(@"nss: game made a MetalFX temporal scaler (Metal 4) %lux%lu -> %lux%lu, color %lu depth %lu motion %lu output %lu, auto exposure %d, content properties %d (scale %.2f-%.2f)",
                     (unsigned long)self.inputWidth, (unsigned long)self.inputHeight, (unsigned long)self.outputWidth, (unsigned long)self.outputHeight,
                     (unsigned long)self.colorTextureFormat, (unsigned long)self.depthTextureFormat, (unsigned long)self.motionTextureFormat,
                     (unsigned long)self.outputTextureFormat, self.isAutoExposureEnabled, self.isInputContentPropertiesEnabled,
                     self.inputContentMinScale, self.inputContentMaxScale);
            if (sc) nssHookScalerClass(object_getClass(sc));
            return sc;
        }));
    }
    lsfg_log(@"nss: watching for MetalFX temporal scalers (upscaler %s)", config.upscaler == 1 ? "NSS" : "MetalFX");
}
