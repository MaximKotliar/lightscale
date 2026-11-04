// Draws the in-game HUD with sample numbers over a test background and saves it as a PNG, to check its look
// without a game. Build and run: hook/test/hud_preview.sh [out.png]
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#import "../unix/lsfg_hud.h"

#import <QuartzCore/QuartzCore.h>

// Fake running totals: a game at 59 fps whose own GPU time drifts between about 8 and 10 ms per frame, with NSS,
// LSFG and LS1 on top.
static CFTimeInterval start;
void lsfgHudReadTotals(LSFGHudTotals *t) {
    const double s = CACurrentMediaTime() - start, frames = s * 59;
    const double game = frames * 9.0 + 6.0 * sin(s * 2.0) * 59 * 0.15;
    t->gameFrames = (long)frames;
    t->upscaleMs = frames * 1.92; t->upscaleFrames = (long)frames;
    t->lsfgMs = frames * 1.21; t->lsfgFrames = (long)frames;
    t->gpuBusyMs = game + t->upscaleMs;
    t->displayMs = frames * 2 * 0.52;
    t->displayPasses = (long)(frames * 2); t->displayPassMs = 0.40;
    t->lsfgInGameWork = 0;
    t->settingsChanges = 0;
}

int main(int argc, char **argv) {
    start = CACurrentMediaTime();
    @autoreleasepool {
        const char *out = argc > 1 ? argv[1] : "hud_preview.png";
        const int w = 1200, h = 760;
        // HUD_SCALE: the HUD's size setting (the hook multiplies the display's pixels per point by it)
        const float scale = 2 * (getenv("HUD_SCALE") ? (float)atof(getenv("HUD_SCALE")) : 1);
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [device newTextureWithDescriptor:d];
        // A busy background: diagonal bands, so the panel's transparency shows.
        uint8_t *pixels = (uint8_t *)malloc((size_t)w * h * 4);
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                uint8_t *p = pixels + ((size_t)y * w + x) * 4;
                const float t = (x + y) / 60.0f;
                p[0] = (uint8_t)(90 + 60 * sinf(t)); p[1] = (uint8_t)(120 + 50 * sinf(t * 0.7f)); p[2] = (uint8_t)(150 + 80 * sinf(t * 0.3f)); p[3] = 255;
            }
        [target replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels bytesPerRow:w * 4];

        LSFGHudSnapshot s = {0};
        s.screenFps = 118; s.gameFps = 59; s.intervalMs = 8.4; s.intervalSdMs = 0.6; s.intervalMaxMs = 12; s.dropped = 1;
        s.refreshHz = 120; s.fgGpuMs = 1.21; s.presentGpuMs = 0.52; s.queuedMs = 14; s.gpuBusy = 0.83; s.upscaleMs = 1.92;
        s.memoryMB = 6900; s.thermal = 1;
        strcpy(s.frameGen, "LSFG 2× performance");
        strcpy(s.upscaler, "NSS mid");
        strcpy(s.scaling, "LS1 1728×1117 → 3456×2234");
        lsfgHudPublish(&s);
        for (int i = 0; i < 240; i++) {
            lsfgHudScreenFrame(8.33f + (i % 37 == 0 ? 4.0f : 0.3f * sinf(i * 0.9f)));
            if (i % 2 == 0) lsfgHudGameFrame(16.7f + 1.5f * sinf(i * 0.3f) + (i == 150 ? 12 : 0));
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        // About a second of frames, so the average has numbers; only the last is kept.
        for (int frame = 0; frame < 60; frame++) {
            usleep(20000);
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            if (frame == 59) [target replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:pixels bytesPerRow:w * 4];
            lsfgHudEncode(cb, target, scale);
            [cb commit];
            [cb waitUntilCompleted];
            if (cb.error) { fprintf(stderr, "GPU error: %s\n", cb.error.description.UTF8String); return 1; }
        }
        [target getBytes:pixels bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(pixels, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        NSURL *url = [NSURL fileURLWithPath:@(out)];
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        CGImageDestinationAddImage(dest, image, NULL);
        BOOL ok = CGImageDestinationFinalize(dest);
        printf("%s %s\n", ok ? "wrote" : "failed to write", out);
        return ok ? 0 : 1;
    }
}
