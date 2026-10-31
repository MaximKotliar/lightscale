// Native (macOS) side of the CrossOver hook.
//
// Wine dlopen()s this library when lsfghook.dll (the PE side) asks for its Unix
// functions, so this code runs inside the game process, next to D3DMetal.
// Stage 1: observe how the game presents frames. Nothing is changed yet.
//
// Switches (environment):
//   LSFG_ENABLE=0   load but install no hooks
//   LSFG_LOG=path   log file (default ~/Library/Logs/lsfg-metal.log)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <os/lock.h>
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
    kMTL4Signal, kMTL4Wait, kNextDrawable, kCounterCount
} Counter;
static const char *counterNames[kCounterCount] = {
    "drawable.present", "drawable.presentAtTime", "drawable.presentAfterMinimumDuration",
    "cmdbuf.presentDrawable", "cmdbuf.presentDrawable:atTime", "cmdbuf.presentDrawable:afterMinimumDuration",
    "mtl4queue.signalDrawable", "mtl4queue.waitForDrawable", "layer.nextDrawable",
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

// Protocol conformance without messaging the class (some runtime classes misbehave).
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

#pragma mark - Hooks

static void installPresentHooks(void) {
    Protocol *drawable = @protocol(CAMetalDrawable), *commandBuffer = @protocol(MTLCommandBuffer);
    BOOL (^isDrawable)(Class) = ^BOOL(Class c) { return conforms(c, drawable); };
    BOOL (^isCommandBuffer)(Class) = ^BOOL(Class c) { return conforms(c, commandBuffer); };

    hookAll(@selector(present), isDrawable, ^id(IMP orig) {
        return ^(id self) {
            bump(kDrawablePresent);
            describeDrawable(self, "drawable.present");
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
    BOOL (^signals)(Class) = ^BOOL(Class c) { return class_respondsToSelector(c, @selector(signalDrawable:)); };
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
    lsfg_log(@"present hooks installed");
}

static void installLayerHook(void) {
    Class layer = [CAMetalLayer class];
    hookAll(@selector(nextDrawable), ^BOOL(Class c) {
        for (Class k = c; k; k = class_getSuperclass(k)) if (k == layer) return YES;
        return NO;
    }, ^id(IMP orig) {
        return ^id(id self) {
            // The GPU driver's command-buffer classes only exist once the game has a device,
            // which is certainly true by the first nextDrawable.
            static dispatch_once_t once;
            dispatch_once(&once, ^{ installPresentHooks(); });
            bump(kNextDrawable);
            return ((id (*)(id, SEL))orig)(self, @selector(nextDrawable));
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
