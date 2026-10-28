// The UIKit face of the lock-screen card engine: the public API the hooks and the settings
// page call. Everything below this file is Core Graphics, so the Mac harness compiles the
// engine without this wrapper; here is where UIImage comes in and goes out.
#import "SGCardEngine.h"
#import "SGCardPrivate.h"
#import "Core/SGCore.h"
#import "Shared/Catalog/SGCatalog.h"

NSDictionary *SGLockCardBuiltinStyles(void) {
    return SGCCoreBuiltinStyles();
}

NSArray<NSDictionary *> *SGLockCardCatalogStyles(void) {
    return SGCCoreCatalogStyles();
}

void SGLockCardRefreshCatalog(void) {
    SGCCoreRefreshCatalog();
}

void SGLockCardSetStyle(NSString *styleID) {
    SGCCoreSetStyle(styleID);
}

NSString *SGLockCardStyleID(void) {
    return SGCCoreStyleID();
}

void SGLockCardRegisterFonts(void) {
    SGCCoreRegisterFontsForStyle(SGLockCardStyleID());
}

UIImage *SGLockCardRender(NSString *styleID, NSDictionary *data, UIImage *cover,
                          CGFloat width, CGFloat height, CGFloat scale, NSString * _Nullable * _Nullable errorOut) {
    CGImageRef image = SGCardRenderCG(styleID, data ?: SGLockCardSampleData(),
                                      cover.CGImage, width, height, scale, errorOut);
    if (!image) return nil;
    return [UIImage imageWithCGImage:image scale:scale orientation:UIImageOrientationUp];
}

// The sample a preview renders with: one line with its timings, a translation, the neighbours.
NSDictionary *SGLockCardSampleData(void) {
    static NSDictionary *data;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        data = @{
            @"kind": @"line",
            @"index": @"3",
            @"count": @"42",
            @"lang": @"en",
            @"dir": @"ltr",
            @"title": @"Midnight Harbour",
            @"artist": @"The Long Wave",
            @"album": @"Tidal Papers",
            @"prev": @"and the streetlights leaned over the water",
            @"prevTime": @"0:42",
            @"time": @"0:58",
            @"translation": @"y las luces se inclinaban sobre el agua",
            @"next": @"I counted the boats going out",
            @"nextTime": @"1:04",
            @"clock": @"1:07",
            @"words": @[
                @{ @"word": @"I", @"i": @0 },
                @{ @"word": @"counted", @"i": @1 },
                @{ @"word": @"the", @"i": @2 },
                @{ @"word": @"harbour", @"i": @3 },
                @{ @"word": @"lights", @"i": @4 },
                @{ @"word": @"going", @"i": @5 },
                @{ @"word": @"out", @"i": @6 },
            ],
        };
    });
    return data;
}
