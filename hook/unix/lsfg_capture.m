// Reference frames, saved losslessly in the game's pixel format and colour space, for judging upscalers.
//
// Control-Option-C in the game (Shift: 10 frames; a sound confirms it, the game doesn't see the keys):
// - with no capture plan: the game's own frame as the game made it, before frame generation, scaling and the HUD;
// - with ~/Library/Application Support/Lightscale/capture-plan.json: each variant in it in turn (settings on top of
//   the game's profile), settled, then a few consecutive real frames as shown, after upscaling and before the HUD and
//   badge; your settings come back at the end. A dev tool, not in the app:
//     {"frames": 3, "settleMs": 2000, "variants": [
//        {"name": "metalfx"}, {"name": "nss-mid", "upscaler": "nss", "nssQuality": "mid"},
//        {"name": "nis", "scaler": "nis", "scalerSharpness": 0.25}]}
//   Keys as in the game's profile (upscaler, nssQuality, scaler, scalerSharpness, scalerPerformance, enabled, ...).
// Or create .../Lightscale/capture containing "COUNT [EVERY_MS]" (picked up within a second): game frames, or the plan
// when it says "plan".
//
// Files: .../Lightscale/captures/<game>-<date>/<variant or "game">-<n>.png: 8-bit PNG for 8-bit frames, 16-bit PNG
// for 10-bit ones (HDR10 included, tagged as such), half-float OpenEXR for RGBA16F; plus plan.txt with what each
// variant ran. Works whenever the overlay runs (frame generation, display scaling or the HUD on); a plan turns the
// HUD on for its run (it's drawn after the capture). Included by lsfghook_unix.m.
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

enum { kCaptureGame = 0, kCaptureFinal = 1 };
static _Atomic int captureLeft[2];       // frames still to save, per stage
static _Atomic long captureEveryUs;      // spacing between them (game stage)
static _Atomic int captureWrites;        // frames copied but not yet on disk
static CFTimeInterval captureNextAt;     // render thread
static int captureIndex[2];
static NSString *captureDir, *captureName;   // set before a capture starts

static NSString *captureStamp(void) {
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd-HHmmss";
    // exePath is the Windows path the PE side reports ("C:\\…\\game.exe")
    NSString *game = [[exePath componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\\/"]]
                      .lastObject stringByDeletingPathExtension];
    return [NSString stringWithFormat:@"%@-%@", game.length ? game : @"game", [df stringFromDate:NSDate.date]];
}

static BOOL captureBusy(void) {
    return atomic_load(&captureLeft[0]) > 0 || atomic_load(&captureLeft[1]) > 0 || atomic_load(&captureWrites) > 0;
}

static void captureFrames(int stage, int count, long everyUs, NSString *dir, NSString *name) {
    captureDir = dir;
    captureName = name;
    captureIndex[stage] = 0;
    captureNextAt = 0;
    atomic_store(&captureEveryUs, everyUs);
    atomic_store(&captureLeft[stage], count);
}

// Game frames (no plan).
static void captureStart(int count, long everyUs) {
    if (captureBusy()) return;
    captureFrames(kCaptureGame, count, everyUs, [[appDataDir() stringByAppendingPathComponent:@"captures"]
                                                 stringByAppendingPathComponent:captureStamp()], @"game");
    lsfg_log(@"capture: %d game frame%s%@", count, count == 1 ? "" : "s",
             everyUs ? [NSString stringWithFormat:@", every %ld ms", everyUs / 1000] : @"");
}

#pragma mark Plan

static _Atomic bool planRequested;
static NSDictionary *plan;               // the running plan (stats timer only)
static int planStep, planWait, planFrames;
static NSString *planDir;
static NSMutableString *planLog;

static NSString *planPath(void) { return [appDataDir() stringByAppendingPathComponent:@"capture-plan.json"]; }

static void planNext(void);

static void planStart(void) {
    NSData *data = [NSData dataWithContentsOfFile:planPath()];
    NSDictionary *p = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *variants = [p isKindOfClass:NSDictionary.class] ? p[@"variants"] : nil;
    if (![variants isKindOfClass:NSArray.class] || variants.count == 0) { lsfg_log(@"capture plan: no variants in %@", planPath()); return; }
    plan = p;
    planFrames = [p[@"frames"] isKindOfClass:NSNumber.class] ? MAX(1, MIN([p[@"frames"] intValue], 60)) : 3;
    planDir = [[appDataDir() stringByAppendingPathComponent:@"captures"] stringByAppendingPathComponent:captureStamp()];
    planLog = [NSMutableString stringWithFormat:@"capture plan, %d frames per variant\n", planFrames];
    planStep = -1;
    lsfg_log(@"capture plan: %lu variants, %d frames each, into %@", (unsigned long)variants.count, planFrames, planDir);
    planNext();
}

static void planFinish(BOOL ok) {
    configOverride = nil;
    applyConfigChanges();
    [NSFileManager.defaultManager createDirectoryAtPath:planDir withIntermediateDirectories:YES attributes:nil error:nil];
    [planLog writeToFile:[planDir stringByAppendingPathComponent:@"plan.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    lsfg_log(@"capture plan: %@; your settings are back", ok ? @"done" : @"stopped");
    plan = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ [[NSSound soundNamed:ok ? @"Glass" : @"Basso"] play]; });
}

// Applies the next variant (on top of the profile, with the HUD on so the overlay runs) and waits for it to settle.
static void planNext(void) {
    NSArray *variants = plan[@"variants"];
    if (++planStep >= (int)variants.count) { planFinish(YES); return; }
    NSDictionary *v = [variants[planStep] isKindOfClass:NSDictionary.class] ? variants[planStep] : @{};
    NSMutableDictionary *o = [v mutableCopy];
    [o removeObjectForKey:@"name"];
    if (!o[@"hud"]) o[@"hud"] = @YES;
    configOverride = o;
    applyConfigChanges();
    const int settleMs = [plan[@"settleMs"] isKindOfClass:NSNumber.class] ? [plan[@"settleMs"] intValue] : 2000;
    planWait = MAX(1, (settleMs + 999) / 1000);
    NSString *name = [v[@"name"] isKindOfClass:NSString.class] ? v[@"name"] : [NSString stringWithFormat:@"variant%d", planStep + 1];
    static const char *upscalers[] = {"MetalFX", "NSS"}, *nss[] = {"low", "mid", "high", "fast"};
    static const char *scalers[] = {"off", "LS1", "FSR", "BCAS", "bicubic", "nearest", "NIS"};
    [planLog appendFormat:@"%@: DLSS replacement %s%s%s, display scaling %s (sharpness %.2f%s), frame generation %s %dx; override %@\n",
                          name, upscalers[config.upscaler ? 1 : 0], config.upscaler ? " " : "", config.upscaler ? nss[MAX(0, MIN(config.nssQuality, 3))] : "",
                          scalers[MAX(0, MIN(config.scaler, 6))], config.scalerSharpness, config.scaler == 1 && config.scalerPerformance ? ", performance" : "",
                          config.enabled ? "on" : "off", config.multiplier,
                          [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil] encoding:NSUTF8StringEncoding]];
    captureName = name;   // for the log line below
    lsfg_log(@"capture plan: %@ (%d of %lu), settling", name, planStep + 1, (unsigned long)variants.count);
}

// Stats timer, once a second: requests, and the plan's next step.
static void captureCheckRequest(void) {
    NSString *request = [appDataDir() stringByAppendingPathComponent:@"capture"];
    if ([NSFileManager.defaultManager fileExistsAtPath:request]) {
        NSString *text = [NSString stringWithContentsOfFile:request encoding:NSUTF8StringEncoding error:nil] ?: @"";
        [NSFileManager.defaultManager removeItemAtPath:request error:nil];
        NSArray<NSString *> *f = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        f = [f filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (f.count > 0 && [f[0] isEqualToString:@"plan"]) atomic_store(&planRequested, true);
        else captureStart(f.count > 0 ? MAX(1, MIN(f[0].intValue, 600)) : 1, f.count > 1 ? MAX(0, f[1].intValue) * 1000L : 0);
    }
    if (atomic_exchange(&planRequested, false) && !plan && !captureBusy()) { planStart(); return; }   // settle from the next second
    if (!plan) return;
    if (planWait > 0) {   // settling
        if (--planWait == 0) {
            captureFrames(kCaptureFinal, planFrames, 0, planDir, captureName);
            planWait = -6;   // then up to 5 seconds for the frames
        }
        return;
    }
    if (!captureBusy()) { planNext(); return; }
    if (++planWait == 0) {   // no frames came: is the overlay showing?
        lsfg_log(@"capture plan: %@ got no frames (is the game showing frames?)", captureName);
        atomic_store(&captureLeft[kCaptureFinal], 0);
        planFinish(NO);
    }
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
            if ([NSFileManager.defaultManager fileExistsAtPath:planPath()]) atomic_store(&planRequested, true);
            else captureStart(shift ? 10 : 1, 0);
            [[NSSound soundNamed:@"Tink"] play];
        }
        return nil;   // the game doesn't get it
    }];
    lsfg_log(@"capture: Control-Option-C saves frames (%@)", [NSFileManager.defaultManager fileExistsAtPath:planPath()] ? @"runs capture-plan.json" : @"the game's own; Shift: 10");
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

// Render thread: if a capture of `stage` is due, copies `frame` to memory on `cb` and writes it once the GPU is done.
// Game stage: in fgEncode, the game's frame. Final stage: in the display pass, a real frame as shown (scaled), before
// the HUD.
static void captureEncode(int stage, id<MTLCommandBuffer> cb, id<MTLTexture> frame, CGColorSpaceRef layerSpace) {
    if (atomic_load(&captureLeft[stage]) <= 0) return;
    if (stage == kCaptureGame) {
        const CFTimeInterval now = CACurrentMediaTime();
        if (now < captureNextAt) return;
        captureNextAt = now + atomic_load(&captureEveryUs) / 1e6;
    }
    atomic_fetch_sub(&captureLeft[stage], 1);

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

    NSString *dir = captureDir;
    NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.png", captureName, ++captureIndex[stage]]];
    CGColorSpaceRef space = layerSpace ? CGColorSpaceRetain(layerSpace) : NULL;
    atomic_fetch_add(&captureWrites, 1);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        if (done.status != MTLCommandBufferStatusCompleted) {
            if (space) CGColorSpaceRelease(space);
            atomic_fetch_sub(&captureWrites, 1);
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            captureWrite([NSData dataWithBytesNoCopy:buffer.contents length:buffer.length freeWhenDone:NO], w, h, format, space, path);
            (void)buffer;   // keeps the buffer alive until written
            if (space) CGColorSpaceRelease(space);
            atomic_fetch_sub(&captureWrites, 1);
        });
    }];
}
