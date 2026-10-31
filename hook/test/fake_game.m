// Mimics how D3DMetal presents (seen in Witcher 3): every frame, one render pass draws
// into the drawable, the command buffer is committed, then -[CAMetalDrawable present].
// Runs at ~30 fps for a few seconds in a small window. Load the hook with
// DYLD_INSERT_LIBRARIES=build/lsfghook.so to test frame generation end to end.
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

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
            double phase = (frame++ % 60) / 60.0;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(phase, 0.3, 1 - phase, 1);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            [cb commit];
            [d present];
            if (CACurrentMediaTime() - start > 6) { [t invalidate]; [NSApp terminate:nil]; }
        }];
        [NSApp run];
    }
    return 0;
}
