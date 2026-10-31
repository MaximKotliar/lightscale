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
// Switches (environment):
//   LSFG_ENABLE=0        load but install no hooks
//   LSFG_FG=0            observe only, no frame generation (default: on)
//   LSFG_FLOW_SCALE=F    motion-estimation resolution, 0.25-1.0 (default 1.0)
//   LSFG_PERFORMANCE=0   use LSFG quality mode (default: performance mode)
//   LSFG_READABLE=0      leave framebufferOnly alone (disables frame generation)
//   LSFG_LATENCY_MS=N    delay before the generated frame is shown (default 10 ms)
//   LSFG_LOG=path        log file (default ~/Library/Logs/lsfg-metal.log)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
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
    kMTL4Signal, kMTL4Wait, kNextDrawable, kGenerated, kCounterCount
} Counter;
static const char *counterNames[kCounterCount] = {
    "drawable.present", "drawable.presentAtTime", "drawable.presentAfterMinimumDuration",
    "cmdbuf.presentDrawable", "cmdbuf.presentDrawable:atTime", "cmdbuf.presentDrawable:afterMinimumDuration",
    "mtl4queue.signalDrawable", "mtl4queue.waitForDrawable", "layer.nextDrawable", "generated",
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
static void hookAll(SEL sel, BOOL (^match)(Class), id (^make)(IMP original)) {
    os_unfair_lock_lock(&hookLock);
    if (!hooked) hooked = [NSMutableSet set];
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
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
    free(classes);
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
static struct {
    bridge_create_fn create;
    bridge_texture_fn input;
    bridge_encode_fn encode;
    bridge_output_fn output;
} bridge;

static BOOL fgEnabled;
static _Atomic int fgState;            // 0 idle, 1 creating, 2 ready, -1 failed
static void *fgContext;
static NSUInteger fgWidth, fgHeight;
static MTLPixelFormat fgFormat;
static __weak CAMetalLayer *fgLayer;   // layer the game's drawables come from
static char kDrawableTargetKey;        // command buffer -> drawable texture it renders into
static os_unfair_lock pendingLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSNumber *, id<CAMetalDrawable>> *pending; // real drawable texture -> generated drawable
static CFTimeInterval lastRealPresent, realInterval;

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

static BOOL envOn(const char *name, BOOL fallback) {
    const char *v = getenv(name);
    return v ? v[0] != '0' : fallback;
}
static float envFloat(const char *name, float fallback) {
    const char *v = getenv(name);
    return v ? (float)atof(v) : fallback;
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
    return bridge.create && bridge.input && bridge.encode && bridge.output;
}

// Builds the LSFG context in the background (pipelines can take a moment).
static void fgCreateContext(id<MTLDevice> device, id<MTLTexture> frame) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&fgState, &expected, 1)) return;
    NSUInteger w = frame.width, h = frame.height;
    MTLPixelFormat format = frame.pixelFormat;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char error[512] = {0};
        float flow = envFloat("LSFG_FLOW_SCALE", 1.0f);
        BOOL perf = envOn("LSFG_PERFORMANCE", YES);
        CFTimeInterval t0 = CACurrentMediaTime();
        void *ctx = bridge.create((__bridge const void *)device, (int)w, (int)h, (unsigned)format, 2, flow, perf, error, sizeof error);
        if (!ctx) {
            lsfg_log(@"frame generation off: %s", error);
            atomic_store(&fgState, -1);
            return;
        }
        fgContext = ctx;
        fgWidth = w; fgHeight = h; fgFormat = format;
        atomic_store(&fgState, 2);
        lsfg_log(@"frame generation ready: %lux%lu fmt %lu, flow %.2f, %s mode, built in %.2fs", (unsigned long)w,
                 (unsigned long)h, (unsigned long)format, flow, perf ? "performance" : "quality", CACurrentMediaTime() - t0);
    });
}

// Commit hook, for the command buffer that renders a real frame into drawable texture `target`.
static void fgEncode(id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    NSNumber *key = @((uintptr_t)(__bridge void *)target);
    os_unfair_lock_lock(&pendingLock);
    [pending removeObjectForKey:key]; // never show a stale generated frame for this drawable
    os_unfair_lock_unlock(&pendingLock);

    int state = atomic_load(&fgState);
    if (state == 0) fgCreateContext(cb.device, target);
    if (state != 2) return;
    if (target.width != fgWidth || target.height != fgHeight || target.pixelFormat != fgFormat) {
        static dispatch_once_t once;
        dispatch_once(&once, ^{ lsfg_log(@"frame size or format changed; frame generation paused (restart the game)"); });
        return;
    }
    id<MTLTexture> input = (__bridge id<MTLTexture>)bridge.input(fgContext);
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:target toTexture:input];
    [blit endEncoding];
    if (bridge.encode(fgContext, (__bridge const void *)cb) <= 0) return; // history still filling

    CAMetalLayer *layer = fgLayer;
    id<CAMetalDrawable> extra = layer ? [layer nextDrawable] : nil;
    if (!extra || extra.texture.width != fgWidth || extra.texture.height != fgHeight) return;
    blit = [cb blitCommandEncoder];
    [blit copyFromTexture:(__bridge id<MTLTexture>)bridge.output(fgContext, 0) toTexture:extra.texture];
    [blit endEncoding];
    os_unfair_lock_lock(&pendingLock);
    pending[key] = extra;
    os_unfair_lock_unlock(&pendingLock);
}

// Present hook for a real drawable. Returns YES if it presented the generated frame and the
// real one itself.
//
// Both are scheduled at absolute times relative to when the game presents (T):
//   generated at T + L, real at T + L + interval / 2.
// L covers the GPU work still running for these frames. Nothing waits on the previous
// frame, so a slow game frame can't push later frames back, drawables never pile up, and
// the game never blocks in nextDrawable. (Chaining presentAfterMinimumDuration did: in
// Witcher 3 it throttled 30 real fps down to 12-15.)
static BOOL fgPresent(id<CAMetalDrawable> real) {
    CFTimeInterval now = CACurrentMediaTime();
    if (lastRealPresent > 0) {
        CFTimeInterval dt = now - lastRealPresent;
        if (dt > 0.004 && dt < 0.25) realInterval = realInterval > 0 ? realInterval * 0.8 + dt * 0.2 : dt;
    }
    lastRealPresent = now;

    NSNumber *key = @((uintptr_t)(__bridge void *)real.texture);
    os_unfair_lock_lock(&pendingLock);
    id<CAMetalDrawable> extra = pending[key];
    [pending removeObjectForKey:key];
    os_unfair_lock_unlock(&pendingLock);
    if (!extra || realInterval <= 0) return NO;

    static double latency = -1;
    if (latency < 0) latency = envFloat("LSFG_LATENCY_MS", 10) / 1000.0;
    CFTimeInterval half = MIN(realInterval, 0.1) / 2;
    trackPresented(extra);
    trackPresented(real);
    [extra presentAtTime:now + latency];
    [real presentAtTime:now + latency + half];
    bump(kGenerated);
    return YES;
}

#pragma mark - Hooks

static void installPresentHooks(void) {
    Protocol *drawable = @protocol(CAMetalDrawable), *commandBuffer = @protocol(MTLCommandBuffer);
    BOOL (^isDrawable)(Class) = ^BOOL(Class c) { return conforms(c, drawable); };
    BOOL (^isCommandBuffer)(Class) = ^BOOL(Class c) { return conforms(c, commandBuffer); };

    hookAll(@selector(present), isDrawable, ^id(IMP orig) {
        return ^(id self) {
            bump(kDrawablePresent);
            describeDrawable(self, "drawable.present");
            int k = atomic_fetch_add(&diagPresents, 1);
            if (k < kDiagFrames) {
                id<MTLCommandBuffer> cb = lastDrawableCB;
                lsfg_log(@"diag present #%d drawable texture %p on %@; last drawable-writing cb %p status %ld",
                         k, (__bridge void *)[(id<CAMetalDrawable>)self texture], threadName(),
                         (__bridge void *)cb, cb ? (long)cb.status : -1L);
            }
            if (fgEnabled && fgPresent(self)) return;
            ((void (*)(id, SEL))orig)(self, @selector(present));
        };
    });
    hookAll(@selector(presentAtTime:), isDrawable, ^id(IMP orig) {
        return ^(id self, CFTimeInterval t) {
            bump(kDrawablePresentAtTime);
            describeDrawable(self, "drawable.presentAtTime");
            ((void (*)(id, SEL, CFTimeInterval))orig)(self, @selector(presentAtTime:), t);
        };
    });
    hookAll(@selector(presentAfterMinimumDuration:), isDrawable, ^id(IMP orig) {
        return ^(id self, CFTimeInterval d) {
            bump(kDrawablePresentAfter);
            describeDrawable(self, "drawable.presentAfterMinimumDuration");
            ((void (*)(id, SEL, CFTimeInterval))orig)(self, @selector(presentAfterMinimumDuration:), d);
        };
    });
    hookAll(@selector(presentDrawable:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d) {
            bump(kCBPresent);
            if (conforms(object_getClass(d), drawable)) describeDrawable(d, "cmdbuf.presentDrawable");
            ((void (*)(id, SEL, id))orig)(self, @selector(presentDrawable:), d);
        };
    });
    hookAll(@selector(presentDrawable:atTime:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d, CFTimeInterval t) {
            bump(kCBPresentAtTime);
            ((void (*)(id, SEL, id, CFTimeInterval))orig)(self, @selector(presentDrawable:atTime:), d, t);
        };
    });
    hookAll(@selector(presentDrawable:afterMinimumDuration:), isCommandBuffer, ^id(IMP orig) {
        return ^(id self, id d, CFTimeInterval t) {
            bump(kCBPresentAfter);
            ((void (*)(id, SEL, id, CFTimeInterval))orig)(self, @selector(presentDrawable:afterMinimumDuration:), d, t);
        };
    });
    BOOL (^signals)(Class) = ^BOOL(Class c) { return conforms(c, @protocol(MTL4CommandQueue)); };
    hookAll(@selector(signalDrawable:), signals, ^id(IMP orig) {
        return ^(id self, id d) {
            bump(kMTL4Signal);
            if (conforms(object_getClass(d), drawable)) describeDrawable(d, "mtl4queue.signalDrawable");
            ((void (*)(id, SEL, id))orig)(self, @selector(signalDrawable:), d);
        };
    });
    hookAll(@selector(waitForDrawable:), signals, ^id(IMP orig) {
        return ^(id self, id d) {
            bump(kMTL4Wait);
            ((void (*)(id, SEL, id))orig)(self, @selector(waitForDrawable:), d);
        };
    });
    // Diagnostics: who writes the drawable.
    hookAll(@selector(renderCommandEncoderWithDescriptor:), isCommandBuffer, ^id(IMP orig) {
        return ^id(id self, MTLRenderPassDescriptor *desc) {
            id enc = ((id (*)(id, SEL, id))orig)(self, @selector(renderCommandEncoderWithDescriptor:), desc);
            id<MTLTexture> target = desc.colorAttachments[0].texture;
            if (fgEnabled && isDrawableTexture(target))
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
            return enc;
        };
    });
    hookAll(@selector(blitCommandEncoder), isCommandBuffer, ^id(IMP orig) {
        return ^id(id self) {
            id enc = ((id (*)(id, SEL))orig)(self, @selector(blitCommandEncoder));
            // Weak link back so a copy into a drawable can find its command buffer.
            if (diagActive() && enc) objc_setAssociatedObject(enc, &kOwnerKey, self, OBJC_ASSOCIATION_ASSIGN);
            return enc;
        };
    });
    hookAll(@selector(commit), isCommandBuffer, ^id(IMP orig) {
        return ^(id self) {
            if (diagActive() && objc_getAssociatedObject(self, &kWritesDrawableKey))
                lsfg_log(@"diag commit of drawable-writing cb %p (presents so far: %d) on %@", (__bridge void *)self,
                         atomic_load(&diagPresents), threadName());
            id<MTLTexture> target = fgEnabled ? objc_getAssociatedObject(self, &kDrawableTargetKey) : nil;
            if (target) {
                objc_setAssociatedObject(self, &kDrawableTargetKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                fgEncode(self, target);
            }
            ((void (*)(id, SEL))orig)(self, @selector(commit));
        };
    });
    Protocol *renderEncoder = @protocol(MTLRenderCommandEncoder), *blitEncoder = @protocol(MTLBlitCommandEncoder);
    Protocol *computeEncoder = @protocol(MTLComputeCommandEncoder);
    hookAll(@selector(setFragmentTexture:atIndex:), ^BOOL(Class c) { return conforms(c, renderEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> t, NSUInteger index) {
            if (diagActive() && objc_getAssociatedObject(self, &kWritesDrawableKey))
                lsfg_log(@"diag drawable pass samples texture[%lu]: %@", (unsigned long)index, describeTexture(t));
            ((void (*)(id, SEL, id, NSUInteger))orig)(self, @selector(setFragmentTexture:atIndex:), t, index);
        };
    });
    hookAll(@selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
            ^BOOL(Class c) { return conforms(c, blitEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> src, NSUInteger ss, NSUInteger sl, MTLOrigin so, MTLSize sz,
                 id<MTLTexture> dst, NSUInteger ds, NSUInteger dl, MTLOrigin dor) {
            if (diagActive() && isDrawableTexture(dst)) {
                markOwnerWritesDrawable(self);
                lsfg_log(@"diag blit copy into drawable from %@ (encoder %@) on %@", describeTexture(src),
                         NSStringFromClass([self class]), threadName());
            }
            ((void (*)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin))orig)(
                self, @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
                src, ss, sl, so, sz, dst, ds, dl, dor);
        };
    });
    hookAll(@selector(copyFromTexture:toTexture:), ^BOOL(Class c) { return conforms(c, blitEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> src, id<MTLTexture> dst) {
            if (diagActive() && isDrawableTexture(dst)) markOwnerWritesDrawable(self);
            if (diagActive() && isDrawableTexture(dst))
                lsfg_log(@"diag blit copy (whole) into drawable from %@ on %@", describeTexture(src), threadName());
            ((void (*)(id, SEL, id, id))orig)(self, @selector(copyFromTexture:toTexture:), src, dst);
        };
    });
    hookAll(@selector(setTexture:atIndex:), ^BOOL(Class c) { return conforms(c, computeEncoder); }, ^id(IMP orig) {
        return ^(id self, id<MTLTexture> t, NSUInteger index) {
            if (diagActive() && isDrawableTexture(t))
                lsfg_log(@"diag compute pass binds drawable at index %lu on %@", (unsigned long)index, threadName());
            ((void (*)(id, SEL, id, NSUInteger))orig)(self, @selector(setTexture:atIndex:), t, index);
        };
    });
    // MTL4 command buffers take an MTL4RenderPassDescriptor (same colorAttachments shape).
    hookAll(@selector(renderCommandEncoderWithDescriptor:), ^BOOL(Class c) { return conforms(c, @protocol(MTL4CommandBuffer)); }, ^id(IMP orig) {
        return ^id(id self, id desc) {
            id enc = ((id (*)(id, SEL, id))orig)(self, @selector(renderCommandEncoderWithDescriptor:), desc);
            id target = [[[desc valueForKey:@"colorAttachments"] objectAtIndexedSubscript:0] valueForKey:@"texture"];
            if (diagActive() && isDrawableTexture(target))
                lsfg_log(@"diag MTL4 render pass into drawable: cb %@ on %@", NSStringFromClass([self class]), threadName());
            return enc;
        };
    });
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
            // The GPU driver's command-buffer classes only exist once the game has a device,
            // which is certainly true by the first nextDrawable. Scanning every class takes
            // about a second, so do it off the game's present path.
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ installPresentHooks(); });
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
            if (--depth == 0 && drawable) {
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
        }
        shownCount = droppedCount = 0; shownSum = shownSumSq = shownMax = 0;
        os_unfair_lock_unlock(&pacingLock);
        if (line.length) lsfg_log(@"per second:%@", line);
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
        fgEnabled = envOn("LSFG_FG", YES) && envOn("LSFG_READABLE", YES) && loadBridge();
        pending = [NSMutableDictionary dictionary];
        lsfg_log(@"frame generation %s", fgEnabled ? "on" : "off");
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
