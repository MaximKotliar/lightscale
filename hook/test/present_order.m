// Which presentation patterns does Core Animation drop? Each "frame" acquires two drawables,
// clears both, commits, then presents them in a given order from the completion handler.
// Usage: present_order MODE GPU_MS   MODE: acq (in acquisition order) | rev (reversed) |
//        sched (presentAtTime before completion) | cbat (cb presentDrawable / presentDrawable:atTime:)
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <os/lock.h>

static int shown, dropped;
static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
static void track(id<CAMetalDrawable> d) {
    [d addPresentedHandler:^(id<MTLDrawable> x) {
        os_unfair_lock_lock(&lock);
        if (x.presentedTime == 0) dropped++; else shown++;
        os_unfair_lock_unlock(&lock);
    }];
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? @(argv[1]) : @"acq";
        double gpuMs = argc > 2 ? atof(argv[2]) : 0;
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSWindow *win = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 480, 270)
                                                    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = dev; layer.drawableSize = CGSizeMake(960, 540);
        win.contentView.wantsLayer = YES; win.contentView.layer = layer;
        [win orderFrontRegardless];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:
            @"kernel void burn(device float *o [[buffer(0)]], constant uint &n [[buffer(1)]], uint i [[thread_position_in_grid]]) {"
            @" float v = i; for (uint k = 0; k < n; k++) v = metal::fma(v, 1.0001f, 0.5f); o[i] = v; }" options:nil error:&e];
        id<MTLComputePipelineState> burn = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"burn"] error:&e];
        id<MTLBuffer> buf = [dev newBufferWithLength:4 << 20 options:MTLResourceStorageModePrivate];
        __block uint32_t iters = 2000;
        CFTimeInterval start = CACurrentMediaTime();
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *t) {
            id<CAMetalDrawable> a = [layer nextDrawable], b = [layer nextDrawable];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            if (gpuMs > 0) {
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:burn]; [ce setBuffer:buf offset:0 atIndex:0]; [ce setBytes:&iters length:4 atIndex:1];
                [ce dispatchThreads:MTLSizeMake(1 << 20, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
                [ce endEncoding];
            }
            for (id<CAMetalDrawable> d in @[a, b]) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = d.texture; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.3, 0.35, 1); // calm, identical: no strobing
                [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            }
            track(a); track(b);
            if ([mode isEqual:@"cbat"]) {
                // Let Metal present once the command buffer is scheduled: first now, second half a frame later.
                CFTimeInterval now = CACurrentMediaTime();
                [cb presentDrawable:a];
                [cb presentDrawable:b atTime:now + gpuMs / 1000 + 0.010 + 1.0 / 60];
                [cb commit];
            } else if ([mode isEqual:@"sched"]) {
                CFTimeInterval now = CACurrentMediaTime();
                [cb commit];
                [a presentAtTime:now + gpuMs / 1000 + 0.010]; [b presentAtTime:now + gpuMs / 1000 + 0.010 + 1.0 / 60];
            } else {
                BOOL rev = [mode isEqual:@"rev"];
                [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                    double ms = (done.GPUEndTime - done.GPUStartTime) * 1000;
                    if (gpuMs > 0 && ms > 0) iters = (uint32_t)MAX(100, MIN(2000000, iters * (0.5 + 0.5 * gpuMs / ms)));
                    CFTimeInterval now = CACurrentMediaTime();
                    id<CAMetalDrawable> first = rev ? b : a, second = rev ? a : b;
                    [first present]; [second presentAtTime:now + 1.0 / 60];
                }];
                [cb commit];
            }
            if (CACurrentMediaTime() - start > 4) {
                [t invalidate];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                    printf("%-5s gpu %2.0f ms: shown %d, dropped %d\n", mode.UTF8String, gpuMs, shown, dropped);
                    [NSApp terminate:nil];
                });
            }
        }];
        [NSApp run];
    }
}
