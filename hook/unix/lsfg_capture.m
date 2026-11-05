// Reference frames: on request, the game's own frames as the game made them (before frame generation, scaling and
// the HUD), saved losslessly in the game's pixel format and colour space, for judging upscalers against.
//
// Request: press Control-Option-C in the game (one frame) or Control-Option-Shift-C (10 consecutive frames); a sound
// confirms it and the game doesn't see the keys. Or create ~/Library/Application Support/Lightscale/capture while
// the game runs; its contents, optional: "COUNT [EVERY_MS]" (default 1 frame; EVERY_MS 0: consecutive frames), picked
// up within a second. Either way the hook writes .../Lightscale/captures/<game>-<date>-<n>.png: 8-bit PNG for 8-bit frames, 16-bit PNG
// for 10-bit ones (HDR10 included, tagged as such), 16-bit float OpenEXR for half-float frames.
// Works whenever the overlay runs (frame generation, display scaling or the HUD on). Included by lsfghook_unix.m.
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static _Atomic int captureLeft;          // frames still to save
static _Atomic long captureEveryUs;      // spacing between them
static CFTimeInterval captureNextAt;     // render thread
static int captureIndex;
static NSString *captureStamp;

static void captureStart(int count, long everyUs) {
    if (atomic_load(&captureLeft) > 0) return;   // one capture at a time
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    captureStamp = [df stringFromDate:NSDate.date];
    captureIndex = 0;
    captureNextAt = 0;
    atomic_store(&captureEveryUs, everyUs);
    atomic_store(&captureLeft, count);
    lsfg_log(@"capture: %d frame%s%@", count, count == 1 ? "" : "s",
             everyUs ? [NSString stringWithFormat:@", every %ld ms", everyUs / 1000] : @"");
}

// Stats timer (once a second): is there a request file?
static void captureCheckRequest(void) {
    NSString *request = [appDataDir() stringByAppendingPathComponent:@"capture"];
    if (![NSFileManager.defaultManager fileExistsAtPath:request]) return;
    NSString *text = [NSString stringWithContentsOfFile:request encoding:NSUTF8StringEncoding error:nil] ?: @"";
    [NSFileManager.defaultManager removeItemAtPath:request error:nil];
    NSArray<NSString *> *f = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    captureStart(f.count > 0 ? MAX(1, MIN(f[0].intValue, 600)) : 1, f.count > 1 ? MAX(0, f[1].intValue) * 1000L : 0);
}

// Control-Option-C (Shift: 10 frames), seen by the game's window (Wine's Mac driver is a Cocoa app). Matched by the
// physical C key (kVK_ANSI_C), so any keyboard layout works. Main thread.
static void captureInstallHotkey(void) {
    static id monitor;
    if (monitor) return;
    monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        const NSEventModifierFlags m = e.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagOption |
                                                          NSEventModifierFlagCommand | NSEventModifierFlagShift);
        const BOOL shift = (m & NSEventModifierFlagShift) != 0;
        if (e.keyCode != 8 || (m & ~NSEventModifierFlagShift) != (NSEventModifierFlagControl | NSEventModifierFlagOption)) return e;
        if (!e.isARepeat) {
            captureStart(shift ? 10 : 1, 0);
            [[NSSound soundNamed:@"Tink"] play];
        }
        return nil;   // the game doesn't get it
    }];
    lsfg_log(@"capture: Control-Option-C saves the game's frame (Shift: 10 frames)");
}

// Writes one frame (bytes as the GPU laid them out) to disk. Background queue.
static void captureWrite(NSData *bytes, NSUInteger w, NSUInteger h, MTLPixelFormat format, CGColorSpaceRef layerSpace,
                         NSString *path) {
    CGColorSpaceRef space = layerSpace ? CGColorSpaceRetain(layerSpace) : CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    size_t bpc = 8, bpp = 32, rowBytes = w * 4;
    CGBitmapInfo info = 0;
    NSData *pixels = bytes;
    CFStringRef type = (__bridge CFStringRef)UTTypePNG.identifier;
    switch (format) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
        info = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst; break;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
        info = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast; break;
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatBGR10A2Unorm: {
        // 10 bits per channel -> 16-bit RGBX (CoreGraphics has no 10-bit layout it writes)
        NSMutableData *out = [NSMutableData dataWithLength:w * h * 8];
        const uint32_t *in = bytes.bytes;
        uint16_t *o = out.mutableBytes;
        const BOOL bgr = format == MTLPixelFormatBGR10A2Unorm;
        for (NSUInteger i = 0; i < w * h; i++) {
            const uint32_t v = in[i];
            const uint32_t a = v & 0x3FF, b = (v >> 10) & 0x3FF, c = (v >> 20) & 0x3FF;
            const uint32_t r = bgr ? c : a, g = b, bl = bgr ? a : c;
            o[i * 4 + 0] = (uint16_t)(r << 6 | r >> 4);
            o[i * 4 + 1] = (uint16_t)(g << 6 | g >> 4);
            o[i * 4 + 2] = (uint16_t)(bl << 6 | bl >> 4);
            o[i * 4 + 3] = 0xFFFF;
        }
        pixels = out; bpc = 16; bpp = 64; rowBytes = w * 8;
        info = kCGBitmapByteOrder16Little | kCGImageAlphaNoneSkipLast;
        break;
    }
    case MTLPixelFormatRGBA16Float:
        bpc = 16; bpp = 64; rowBytes = w * 8;
        info = kCGBitmapByteOrder16Little | kCGImageAlphaNoneSkipLast | kCGBitmapFloatComponents;
        type = (__bridge CFStringRef)UTTypeEXR.identifier;
        path = [path.stringByDeletingPathExtension stringByAppendingPathExtension:@"exr"];
        if (!layerSpace) { CGColorSpaceRelease(space); space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB); }
        break;
    default:
        lsfg_log(@"capture: pixel format %lu isn't supported", (unsigned long)format);
        CGColorSpaceRelease(space);
        return;
    }
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image = CGImageCreate(w, h, bpc, bpp, rowBytes, space, info, provider, NULL, false, kCGRenderingIntentDefault);
    BOOL ok = NO;
    if (image) {
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], type, 1, NULL);
        if (dest) {
            CGImageDestinationAddImage(dest, image, NULL);
            ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(image);
    }
    CGDataProviderRelease(provider);
    CFStringRef name = CGColorSpaceCopyName(space);
    lsfg_log(@"capture: %@ %@ (%lux%lu, format %lu, %@)", ok ? @"wrote" : @"failed to write", path, (unsigned long)w,
             (unsigned long)h, (unsigned long)format, name ? (__bridge NSString *)name : @"no colour space");
    if (name) CFRelease(name);
    CGColorSpaceRelease(space);
}

// Render thread, inside fgEncode: if a capture is due, copies `frame` (the game's own) to memory on `cb` and writes
// it once the GPU is done.
static void captureEncode(id<MTLCommandBuffer> cb, id<MTLTexture> frame, CAMetalLayer *layer) {
    if (atomic_load(&captureLeft) <= 0) return;
    const CFTimeInterval now = CACurrentMediaTime();
    if (now < captureNextAt) return;
    captureNextAt = now + atomic_load(&captureEveryUs) / 1e6;
    atomic_fetch_sub(&captureLeft, 1);

    const NSUInteger w = frame.width, h = frame.height;
    const MTLPixelFormat format = frame.pixelFormat;
    const NSUInteger pixelBytes = format == MTLPixelFormatRGBA16Float ? 8 : 4;
    id<MTLBuffer> buffer = [cb.device newBufferWithLength:w * h * pixelBytes options:MTLResourceStorageModeShared];
    if (!buffer) { lsfg_log(@"capture: out of memory"); return; }
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    blit.label = @"Lightscale capture";
    [blit copyFromTexture:frame sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buffer destinationOffset:0 destinationBytesPerRow:w * pixelBytes destinationBytesPerImage:w * h * pixelBytes];
    [blit endEncoding];

    NSString *dir = [appDataDir() stringByAppendingPathComponent:@"captures"];
    // exePath is the Windows path the PE side reports ("C:\\…\\game.exe")
    NSString *game = [[exePath componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/"]]
                      .lastObject stringByDeletingPathExtension];
    if (!game.length) game = @"game";
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@-%03d.png", game, captureStamp, ++captureIndex]];
    CGColorSpaceRef space = layer.colorspace ? CGColorSpaceRetain(layer.colorspace) : NULL;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) { if (space) CGColorSpaceRelease(space); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            captureWrite([NSData dataWithBytesNoCopy:buffer.contents length:buffer.length freeWhenDone:NO], w, h, format, space, path);
            (void)buffer;   // keeps the buffer alive until written
            if (space) CGColorSpaceRelease(space);
        });
    }];
}
