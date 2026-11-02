// Drives a real MetalFX temporal scaler the way D3DMetal does, so the hook's NSS path can be tested without a game.
// Load the hook with DYLD_INSERT_LIBRARIES=$PWD/build/lsfghook.so and LSFG_UPSCALER=nss; compare against a run
// without it. Renders a moving pattern with Halton jitter and writes the last output to a PNG.
//   nss_hook_test <out.png> [frames]      TEST_MTL4=1: a Metal 4 scaler and command buffers, like GPTK 4
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const char *kSrc =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct A { float2 jitter; float t; float2 outScale; };\n"
    "static float3 scene(float2 p, float t) {\n"
    "  float2 q = p + float2(3.0 * t, 0);\n"
    "  float v = (fract(q.x / 23.0) < 0.15 || fract(q.y / 17.0) < 0.15) ? 1.0 : 0.15;\n"
    "  float2 c = p - float2(400 + 200 * sin(t * 0.05), 300);\n"
    "  if (length(c) < 120) v = fract(atan2(c.y, c.x) * 6.0) < 0.5 ? 0.9 : 0.1;\n"
    "  return float3(v, v * 0.8, 0.3 + 0.5 * v);\n"
    "}\n"
    "kernel void render(constant A& a [[buffer(0)]], texture2d<float, access::write> col [[texture(0)]],\n"
    "                   texture2d<float, access::write> dep [[texture(1)]], texture2d<float, access::write> mv [[texture(2)]],\n"
    "                   uint2 g [[thread_position_in_grid]]) {\n"
    "  if (g.x >= col.get_width() || g.y >= col.get_height()) return;\n"
    "  float2 p = (float2(g) + 0.5 + a.jitter) * a.outScale;\n"
    "  col.write(float4(scene(p, a.t), 1), g);\n"
    "  float2 c = p - float2(400 + 200 * sin(a.t * 0.05), 300);\n"
    "  bool disc = length(c) < 120;\n"
    "  dep.write(float4(disc ? 0.6 : 0.2), g);\n"
    "  float2 prevMinusCur = disc ? float2(200 * (sin((a.t - 1) * 0.05) - sin(a.t * 0.05)), 0) : float2(-3, 0);\n"
    "  mv.write(float4(prevMinusCur / a.outScale, 0, 0), g);\n"
    "}\n";

static float halton(int i, int b) { float f = 1, r = 0; for (; i > 0; i /= b) f /= b, r += f * (i % b); return r; }

int main(int argc, char **argv) {
    @autoreleasepool {
        // TEST_SIZE=WrxHr:WoxHo (default 640x360:1280x720; TLOU2 Balanced is 1488x928:2560x1600)
        int Wr = 640, Hr = 360, Wo = 1280, Ho = 720;
        if (getenv("TEST_SIZE")) sscanf(getenv("TEST_SIZE"), "%dx%d:%dx%d", &Wr, &Hr, &Wo, &Ho);
        const int frames = argc > 2 ? atoi(argv[2]) : 32;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *e = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSrc) options:nil error:&e];
        if (!lib) { NSLog(@"%@", e); return 1; }
        id<MTLComputePipelineState> render = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"render"] error:&e];
        MTLFXTemporalScalerDescriptor *d = [MTLFXTemporalScalerDescriptor new];
        d.colorTextureFormat = MTLPixelFormatRGBA16Float, d.depthTextureFormat = MTLPixelFormatDepth32Float;
        d.motionTextureFormat = MTLPixelFormatRG16Float, d.outputTextureFormat = MTLPixelFormatRGBA16Float;
        d.inputWidth = Wr, d.inputHeight = Hr, d.outputWidth = Wo, d.outputHeight = Ho;
        const BOOL mtl4 = getenv("TEST_MTL4") && getenv("TEST_MTL4")[0] == '1';
        id<MTLFXTemporalScaler> fx = nil;
        id<MTL4FXTemporalScaler> fx4 = nil;
        id<MTL4CommandQueue> q4 = nil;
        id<MTL4CommandAllocator> alloc = nil;
        id<MTLSharedEvent> ev = nil;
        if (mtl4) {
            id<MTL4Compiler> compiler = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
            fx4 = [d newTemporalScalerWithDevice:dev compiler:compiler];
            q4 = [dev newMTL4CommandQueue];
            alloc = [dev newCommandAllocator];
            ev = [dev newSharedEvent];
        } else {
            fx = [d newTemporalScalerWithDevice:dev];
        }
        if (!fx && !fx4) { NSLog(@"no MetalFX"); return 1; }
        id<MTLFXTemporalScalerBase> fxb = mtl4 ? (id<MTLFXTemporalScalerBase>)fx4 : (id<MTLFXTemporalScalerBase>)fx;
        MTLTextureDescriptor *t = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:Wr height:Hr mipmapped:NO];
        t.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        t.storageMode = MTLStorageModePrivate;
        id<MTLTexture> color = [dev newTextureWithDescriptor:t];
        t.pixelFormat = MTLPixelFormatR32Float;
        id<MTLTexture> depthW = [dev newTextureWithDescriptor:t];
        t.pixelFormat = MTLPixelFormatDepth32Float, t.usage = fxb.depthTextureUsage | MTLTextureUsageShaderRead;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:t];
        t.pixelFormat = MTLPixelFormatRG16Float, t.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> motion = [dev newTextureWithDescriptor:t];
        MTLTextureDescriptor *o = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:Wo height:Ho mipmapped:NO];
        o.usage = fxb.outputTextureUsage | MTLTextureUsageShaderRead;
        o.storageMode = MTLStorageModeShared;
        id<MTLTexture> out = [dev newTextureWithDescriptor:o];
        id<MTLBuffer> depthBuf = [dev newBufferWithLength:(size_t)Wr * Hr * 4 options:MTLResourceStorageModePrivate];
        if (mtl4) {   // Metal 4: the queue's residency set holds the textures MetalFX touches
            MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
            id<MTLResidencySet> rs = [dev newResidencySetWithDescriptor:rd error:&e];
            for (id<MTLAllocation> a in @[color, depth, motion, out]) [rs addAllocation:a];
            [rs commit];
            [q4 addResidencySet:rs];
        }
        printf("output usage 0x%lx\n", (unsigned long)out.usage);
        for (int f = 0; f < frames; f++) {
            const float jx = halton(f % 16 + 1, 2) - 0.5f, jy = halton(f % 16 + 1, 3) - 0.5f;
            struct { float jitter[2]; float t; float pad; float outScale[2]; } a = {{jx, jy}, (float)f, 0, {(float)Wo / Wr, (float)Ho / Hr}};   // float2 is 8-aligned in Metal
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> c = [cb computeCommandEncoder];
            [c setComputePipelineState:render];
            [c setBytes:&a length:sizeof(a) atIndex:0];
            [c setTexture:color atIndex:0], [c setTexture:depthW atIndex:1], [c setTexture:motion atIndex:2];
            [c dispatchThreads:MTLSizeMake(Wr, Hr, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
            [c endEncoding];
            id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];   // R32F -> Depth32Float (via a buffer), like a game's depth buffer
            [b copyFromTexture:depthW sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(Wr, Hr, 1)
                      toBuffer:depthBuf destinationOffset:0 destinationBytesPerRow:Wr * 4 destinationBytesPerImage:(NSUInteger)Wr * Hr * 4];
            [b copyFromBuffer:depthBuf sourceOffset:0 sourceBytesPerRow:Wr * 4 sourceBytesPerImage:(NSUInteger)Wr * Hr * 4
                   sourceSize:MTLSizeMake(Wr, Hr, 1) toTexture:depth destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
            [b endEncoding];
            fxb.colorTexture = color, fxb.depthTexture = depth, fxb.motionTexture = motion, fxb.outputTexture = out;
            fxb.jitterOffsetX = -jx, fxb.jitterOffsetY = -jy, fxb.motionVectorScaleX = 1, fxb.motionVectorScaleY = 1;
            fxb.depthReversed = YES, fxb.reset = f == 0;
            if (!mtl4) {
                [fx encodeToCommandBuffer:cb];
                [cb commit];
                [cb waitUntilCompleted];
                if (cb.error) { NSLog(@"frame %d: %@", f, cb.error); return 1; }
            } else {
                [cb commit];   // inputs on the Metal 3 queue first
                [cb waitUntilCompleted];
                [alloc reset];
                id<MTL4CommandBuffer> c4 = [dev newCommandBuffer];
                [c4 beginCommandBufferWithAllocator:alloc];
                [fx4 encodeToCommandBuffer:c4];
                [c4 endCommandBuffer];
                const id<MTL4CommandBuffer> list[1] = {c4};
                [q4 commit:list count:1];
                [q4 signalEvent:ev value:f + 1];
                if (![ev waitUntilSignaledValue:f + 1 timeoutMS:5000]) { NSLog(@"frame %d: Metal 4 timeout", f); return 1; }
            }
        }
        // PNG of the last output
        uint16_t *px = malloc((size_t)Wo * Ho * 8);
        [out getBytes:px bytesPerRow:Wo * 8 fromRegion:MTLRegionMake2D(0, 0, Wo, Ho) mipmapLevel:0];
        uint8_t *rgba = malloc((size_t)Wo * Ho * 4);
        double sum = 0;
        for (size_t i = 0; i < (size_t)Wo * Ho * 4; i++) {
            float v = (float)((_Float16 *)px)[i];
            if (i % 4 != 3) sum += v;
            rgba[i] = (uint8_t)fminf(fmaxf(v, 0), 1) * 0 + (uint8_t)lrintf(fminf(fmaxf(v, 0), 1) * 255);
        }
        printf("mean output %.4f\n", sum / ((double)Wo * Ho * 3));
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(rgba, Wo, Ho, 8, Wo * 4, cs, kCGImageAlphaNoneSkipLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])],
                                                                    (__bridge CFStringRef)UTTypePNG.identifier, 1, nil);
        CGImageDestinationAddImage(dst, img, nil);
        CGImageDestinationFinalize(dst);
        printf("wrote %s\n", argv[1]);
    }
    return 0;
}
