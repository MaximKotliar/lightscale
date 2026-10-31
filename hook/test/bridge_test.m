// x86_64 smoke test for liblsfgbridge.dylib, run under Rosetta like the hook.
// Feeds three synthetic RGB10A2 frames (a bright square moving right) and checks
// that the generated frame is non-empty and the GPU reports no errors.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

typedef void *(*create_fn)(const void *, int, int, unsigned, int, float, int, char *, int);
typedef const void *(*tex_fn)(void *);
typedef int (*encode_fn)(void *, const void *);
typedef const void *(*out_fn)(void *, int);

int main(int argc, const char **argv) {
    @autoreleasepool {
        void *lib = dlopen(argv[1], RTLD_NOW);
        if (!lib) { printf("dlopen: %s\n", dlerror()); return 1; }
        create_fn create = dlsym(lib, "lsfg_bridge_create");
        tex_fn input = dlsym(lib, "lsfg_bridge_input");
        encode_fn encode = dlsym(lib, "lsfg_bridge_encode");
        out_fn output = dlsym(lib, "lsfg_bridge_output");
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const int W = 1728, H = 1117;
        char err[256] = {0};
        CFTimeInterval t0 = CACurrentMediaTime();
        void *ctx = create((__bridge const void *)dev, W, H, MTLPixelFormatRGB10A2Unorm, 2, 1.0f, 1, err, sizeof err);
        if (!ctx) { printf("create failed: %s\n", err); return 1; }
        printf("created in %.2fs on %s (%s)\n", CACurrentMediaTime() - t0, dev.name.UTF8String,
               NSProcessInfo.processInfo.processorCount ? "ok" : "");
        uint32_t *pixels = calloc(W * H, 4);
        int valid = 0;
        for (int f = 0; f < 4; f++) {
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
                int inSquare = x >= 300 + f * 60 && x < 500 + f * 60 && y >= 400 && y < 600;
                uint32_t v = inSquare ? 1000 : (uint32_t)((x * 400) / W);
                pixels[y * W + x] = v | (v << 10) | (v << 20) | (3u << 30); // RGB10A2
            }
            id<MTLTexture> in = (__bridge id<MTLTexture>)input(ctx);
            id<MTLTexture> staging = [dev newTextureWithDescriptor:[MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:W height:H mipmapped:NO]];
            [staging replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:pixels bytesPerRow:W * 4];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit copyFromTexture:staging toTexture:in];
            [blit endEncoding];
            CFTimeInterval e0 = CACurrentMediaTime();
            valid = encode(ctx, (__bridge const void *)cb);
            double encodeMs = (CACurrentMediaTime() - e0) * 1000;
            [cb commit];
            [cb waitUntilCompleted];
            printf("frame %d: valid=%d encode %.3f ms cpu, gpu %.2f ms, error %s\n", f, valid, encodeMs,
                   (cb.GPUEndTime - cb.GPUStartTime) * 1000, cb.error ? cb.error.localizedDescription.UTF8String : "none");
        }
        id<MTLTexture> out = (__bridge id<MTLTexture>)output(ctx, 0);
        id<MTLTexture> read = [dev newTextureWithDescriptor:[MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatRGB10A2Unorm width:W height:H mipmapped:NO]];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:out toTexture:read];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        [read getBytes:pixels bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        // The square is at x=420..620 in frame 2 and 480..680 in frame 3: the midpoint is ~450..650.
        long bright = 0, sumX = 0;
        for (int y = 400; y < 600; y++) for (int x = 0; x < W; x++)
            if ((pixels[y * W + x] & 1023) > 900) { bright++; sumX += x; }
        printf("generated frame: %ld bright pixels, square center x = %.0f (expected ~550)\n",
               bright, bright ? (double)sumX / bright : -1.0);
        return bright > 0 ? 0 : 2;
    }
}
