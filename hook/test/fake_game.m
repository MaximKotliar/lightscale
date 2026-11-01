// Mimics how D3DMetal presents (seen in Witcher 3): every frame, one render pass draws
// into the drawable, the command buffer is committed, then -[CAMetalDrawable present].
// Runs at ~30 fps for a few seconds in a small window. Load the hook with
// DYLD_INSERT_LIBRARIES=build/lsfghook.so to test frame generation end to end.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <pthread.h>

static void *threadMain(void *block) {
    ((__bridge void (^)(void))block)();
    return NULL;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 640, 360)
                                                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        win.title = @"lsfg fake game";
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.pixelFormat = MTLPixelFormatRGB10A2Unorm;
        // FAKE_SIZE=WxH: drawable size (default 1280x720).
        int fw = 1280, fh = 720;
        if (getenv("FAKE_SIZE")) sscanf(getenv("FAKE_SIZE"), "%dx%d", &fw, &fh);
        layer.drawableSize = CGSizeMake(fw, fh);
        win.contentView.wantsLayer = YES;
        win.contentView.layer = layer;
        // Float above other windows: macOS throttles the display link and reports frames as not
        // presented when the window is covered, which would skew every measurement.
        win.level = NSFloatingWindowLevel;
        [win orderFrontRegardless];
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        // FAKE_GPU_MS=N: add about N ms of GPU work before the drawable pass, like a GPU-bound game.
        double gpuMs = getenv("FAKE_GPU_MS") ? atof(getenv("FAKE_GPU_MS")) : 0;
        NSError *libError = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:
            @"kernel void burn(device float *out [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) {"
            @"  float v = i; for (uint k = 0; k < n; k++) v = metal::fma(v, 1.0001f, 0.5f); out[i] = v; }" options:nil error:&libError];
        if (!lib) { NSLog(@"%@", libError); return 1; }
        id<MTLComputePipelineState> burn = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"burn"] error:nil];
        id<MTLBuffer> burnOut = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModePrivate];
        __block uint32_t burnIters = 2000;
        __block int frame = 0;
        CFTimeInterval start = CACurrentMediaTime();
        // FAKE_JITTER=1: frame times vary 28-38 ms like a real game instead of a steady 33.3.
        BOOL jitter = getenv("FAKE_JITTER") != NULL;
        double fps = getenv("FAKE_FPS") ? atof(getenv("FAKE_FPS")) : 30, defaultFps = fps;
        double seconds = getenv("FAKE_SECONDS") ? atof(getenv("FAKE_SECONDS")) : 6;
        // FAKE_MTL4=1: present the way D3DMetal 4 (GPTK 4) does: a Metal 4 command buffer renders
        // into the drawable, then waitForDrawable, commit:count:, signalDrawable, present.
        BOOL mtl4 = getenv("FAKE_MTL4") != NULL;
        enum { kInFlight = 3 };
        id<MTL4CommandQueue> queue4 = mtl4 ? [dev newMTL4CommandQueue] : nil;
        NSMutableArray<id<MTL4CommandAllocator>> *allocators = [NSMutableArray array];
        NSMutableArray<id<MTL4CommandBuffer>> *buffers4 = [NSMutableArray array], *uiBuffers4 = [NSMutableArray array];
        id<MTLSharedEvent> done4 = mtl4 ? [dev newSharedEvent] : nil;
        if (mtl4) {
            [queue4 addResidencySet:layer.residencySet];
            for (int i = 0; i < kInFlight; i++) { [allocators addObject:[dev newCommandAllocator]]; [buffers4 addObject:[dev newCommandBuffer]]; [uiBuffers4 addObject:[dev newCommandBuffer]]; }
        }
        __block uint64_t submitted4 = 0;
        void (^renderFrame)(void) = ^{
            if (jitter) usleep(arc4random_uniform(10000));
            id<CAMetalDrawable> d = [layer nextDrawable];
            if (!d) return;
            if (mtl4) {
                // Reuse an allocator only once the GPU has finished the frame that used it.
                if (submitted4 >= kInFlight) [done4 waitUntilSignaledValue:submitted4 - kInFlight + 1 timeoutMS:1000];
                int i = (int)(submitted4 % kInFlight);
                [allocators[i] reset];
                id<MTL4CommandBuffer> cb4 = buffers4[i];
                [cb4 beginCommandBufferWithAllocator:allocators[i]];
                MTL4RenderPassDescriptor *rp4 = [MTL4RenderPassDescriptor new];
                rp4.colorAttachments[0].texture = d.texture;
                rp4.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp4.colorAttachments[0].storeAction = MTLStoreActionStore;
                double phase = 0.5 + 0.5 * sin(frame++ * 2 * M_PI / 300);
                rp4.colorAttachments[0].clearColor = MTLClearColorMake(0.2 + 0.1 * phase, 0.3, 0.4 - 0.1 * phase, 1);
                [[cb4 renderCommandEncoderWithDescriptor:rp4] endEncoding];
                [cb4 endCommandBuffer];
                [queue4 waitForDrawable:d];
                [queue4 commit:&cb4 count:1];
                // FAKE_MTL4_PASSES=2: like TLOU Part II on GPTK 4, a second submission draws into the
                // drawable again (the UI, over the scene) before it's handed to the display.
                if (getenv("FAKE_MTL4_PASSES") && atoi(getenv("FAKE_MTL4_PASSES")) > 1) {
                    id<MTL4CommandBuffer> ui = uiBuffers4[i];
                    [ui beginCommandBufferWithAllocator:allocators[i]];
                    MTL4RenderPassDescriptor *over = [MTL4RenderPassDescriptor new];
                    over.colorAttachments[0].texture = d.texture;
                    over.colorAttachments[0].loadAction = MTLLoadActionLoad;
                    over.colorAttachments[0].storeAction = MTLStoreActionStore;
                    [[ui renderCommandEncoderWithDescriptor:over] endEncoding];
                    [ui endCommandBuffer];
                    [queue4 commit:&ui count:1];
                }
                [queue4 signalDrawable:d];
                [queue4 signalEvent:done4 value:++submitted4];
                [d present];
                return;
            }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = d.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            // Slow, gentle color drift (one cycle per 10 s): no flashing.
            double phase = 0.5 + 0.5 * sin(frame++ * 2 * M_PI / 300);
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.2 + 0.1 * phase, 0.3, 0.4 - 0.1 * phase, 1);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            if (gpuMs > 0) {
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:burn];
                [ce setBuffer:burnOut offset:0 atIndex:0];
                [ce setBytes:&burnIters length:4 atIndex:1];
                [ce dispatchThreads:MTLSizeMake(1 << 20, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [ce endEncoding];
                [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                    // Steer the loop count toward the requested GPU time. FAKE_GPU_FREEZE=N: stop
                    // steering after N seconds and report how long that fixed work takes (every
                    // 10 s on stderr), to see the GPU slow down as it heats.
                    double ms = (done.GPUEndTime - done.GPUStartTime) * 1000;
                    static double freezeAt = -1, sum, lastReport;
                    static int n;
                    if (freezeAt < 0) freezeAt = getenv("FAKE_GPU_FREEZE") ? atof(getenv("FAKE_GPU_FREEZE")) : 1e9;
                    double now = CACurrentMediaTime() - start;
                    if (now < freezeAt) {
                        if (ms > 0) burnIters = (uint32_t)MAX(100, MIN(2000000, burnIters * (0.5 + 0.5 * gpuMs / ms)));
                    } else if (ms > 0) {
                        sum += ms; n++;
                        if (now - lastReport >= 10) {
                            fprintf(stderr, "%4.0fs  fixed GPU work %6.2f ms  (%d frames)  thermal %ld\n", now, sum / n, n,
                                    (long)NSProcessInfo.processInfo.thermalState);
                            sum = 0; n = 0; lastReport = now;
                        }
                    }
                }];
            }
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            [cb commit];
            [d present];
        };
        if (getenv("FAKE_THREAD")) {
            // FAKE_THREAD=1: render from a plain thread (like the game's threads under Wine), where only
            // the pool the game drains each frame frees autoreleased objects.
            static void (^loop)(void);
            loop = ^{
                while (CACurrentMediaTime() - start < seconds) {
                    CFTimeInterval t0 = CACurrentMediaTime();
                    // FAKE_FPS_PLAN=30:8,90:8,30:8: frame rate changes over time (fps:seconds, ...).
                    double fps = defaultFps;
                    if (getenv("FAKE_FPS_PLAN")) {
                        double at = t0 - start, edge = 0;
                        for (NSString *step in [@(getenv("FAKE_FPS_PLAN")) componentsSeparatedByString:@","]) {
                            NSArray *parts = [step componentsSeparatedByString:@":"];
                            fps = [parts[0] doubleValue];
                            edge += parts.count > 1 ? [parts[1] doubleValue] : 1e9;
                            if (at < edge) break;
                        }
                    }
                    // Like a real engine: a pool per frame. FAKE_THREAD=2 skips it (nothing is ever freed).
                    if (getenv("FAKE_THREAD")[0] == '2') renderFrame();
                    else @autoreleasepool { renderFrame(); }
                    double left = 1.0 / fps - (CACurrentMediaTime() - t0);
                    if (left > 0) usleep((useconds_t)(left * 1e6));
                }
                dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
            };
            pthread_t thread;
            pthread_create(&thread, NULL, threadMain, (__bridge void *)loop);
        } else {
            [NSTimer scheduledTimerWithTimeInterval:1.0 / fps repeats:YES block:^(NSTimer *t) {
                renderFrame();
                if (CACurrentMediaTime() - start > seconds) { [t invalidate]; [NSApp terminate:nil]; }
            }];
        }
        [NSApp run];
    }
    return 0;
}
