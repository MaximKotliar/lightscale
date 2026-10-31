// Mimics how D3DMetal presents (seen in Witcher 3): every frame, one render pass draws
// into the drawable, the command buffer is committed, then -[CAMetalDrawable present].
// Runs at ~30 fps for a few seconds in a small window. Load the hook with
// DYLD_INSERT_LIBRARIES=build/lsfghook.so to test frame generation end to end.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>

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
        layer.drawableSize = CGSizeMake(1280, 720);
        win.contentView.wantsLayer = YES;
        win.contentView.layer = layer;
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
        [NSTimer scheduledTimerWithTimeInterval:1.0 / (getenv("FAKE_FPS") ? atof(getenv("FAKE_FPS")) : 30) repeats:YES block:^(NSTimer *t) {
            if (jitter) usleep(arc4random_uniform(10000));
            id<CAMetalDrawable> d = [layer nextDrawable];
            if (!d) return;
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
                    // Steer the loop count toward the requested GPU time.
                    double ms = (done.GPUEndTime - done.GPUStartTime) * 1000;
                    if (ms > 0) burnIters = (uint32_t)MAX(100, MIN(2000000, burnIters * (0.5 + 0.5 * gpuMs / ms)));
                }];
            }
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            [cb commit];
            [d present];
            if (CACurrentMediaTime() - start > 6) { [t invalidate]; [NSApp terminate:nil]; }
        }];
        [NSApp run];
    }
    return 0;
}
