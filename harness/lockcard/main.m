// The harness: renders every builtin, then every catalog style it finds, at phone size with
// sample data, writes a PNG per style, and asserts the output is not blank. run.py compiles
// the engine's Core Graphics files (no UIKit, no Theos) with the address sanitizer, points
// HOME at a scratch folder with the catalog in place, and runs this once. A long line
// exercises the --fit search; a broken style must fail with a reason rather than crash.
#import "SGCardPrivate.h"
#import <ImageIO/ImageIO.h>
#import <CoreServices/CoreServices.h>

static int failures = 0;

static void check(BOOL ok, NSString *what) {
    printf("%s  %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

// A synthetic cover: a blue-to-orange gradient, so the aspect-fill crop has something to crop.
static CGImageRef makeCover(CGSize size) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, size.width, size.height, 8, 0, space,
                                             kCGImageAlphaPremultipliedLast);
    CGColorRef colors[2] = { CGColorCreateGenericRGB(0.16, 0.35, 0.75, 1),
                             CGColorCreateGenericRGB(0.95, 0.55, 0.2, 1) };
    CFArrayRef array = CFArrayCreate(NULL, (const void **)colors, 2, &kCFTypeArrayCallBacks);
    CGGradientRef gradient = CGGradientCreateWithColors(space, array, NULL);
    CGContextDrawLinearGradient(ctx, gradient, CGPointMake(0, 0), CGPointMake(size.width, size.height), 0);
    for (int i = 0; i < 2; i++) CGColorRelease(colors[i]);
    CFRelease(array);
    CGGradientRelease(gradient);
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    return image;
}

static NSDictionary *sampleData(void) {
    return @{
        @"kind": @"line",
        @"index": @"3",
        @"count": @"42",
        @"lang": @"en",
        @"dir": @"ltr",
        @"safeTop": @59,
        @"safeBottom": @34,
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
}

// The share of pixels that must be something other than fully transparent for a render to
// count as drawn.
static CGFloat inkShare(CGImageRef image) {
    if (!image) return 0;
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    const UInt8 *bytes = CGBitmapContextGetData(ctx);
    size_t stride = CGBitmapContextGetBytesPerRow(ctx);
    size_t ink = 0, total = 0;
    for (size_t y = 0; y < h; y += 4) {
        for (size_t x = 0; x < w; x += 4) {
            total++;
            if (bytes[y * stride + x * 4 + 3] > 16) ink++;
        }
    }
    CGContextRelease(ctx);
    return total ? (CGFloat)ink / total : 0;
}

static BOOL writePNG(CGImageRef image, NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)url,
                                                                       (__bridge CFStringRef)@"public.png", 1, NULL);
    if (!destination) return NO;
    CGImageDestinationAddImage(destination, image, NULL);
    BOOL ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return ok;
}

static void renderAndCheck(NSString *identifier, NSDictionary *data, CGImageRef cover,
                           NSString *directory, BOOL longLine) {
    NSMutableDictionary *render = [data mutableCopy];
    if (longLine) {
        // a line no pass at --fit 1 could hold: the search has to shrink
        NSMutableString *line = [NSMutableString string];
        for (int i = 0; i < 60; i++) [line appendString:@"incredible "];
        render[@"time"] = line;
        render[@"words"] = @[];
    }
    NSString *error = nil;
    CGImageRef image = SGCardRenderCG(identifier, render, cover, 393, 852, 2, &error);
    if (!image) {
        check(NO, [NSString stringWithFormat:@"%@ rendered: %@", identifier, error ?: @"no reason"]);
        return;
    }
    CGFloat share = inkShare(image);
    check(share > 0.02, [NSString stringWithFormat:@"%@ drew (%.1f%% ink)", identifier, share * 100]);
    NSString *name = [identifier stringByReplacingOccurrencesOfString:@":" withString:@"-"];
    if (longLine) name = [name stringByAppendingString:@"-longline"];
    writePNG(image, [directory stringByAppendingFormat:@"/%@.png", name]);
    CGImageRelease(image);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *outDirectory = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"out";
        [[NSFileManager defaultManager] createDirectoryAtPath:outDirectory
                                  withIntermediateDirectories:YES attributes:nil error:nil];

        CGImageRef cover = makeCover(CGSizeMake(300, 300));
        NSDictionary *data = sampleData();

        // the builtins, then the fit search with a line far too long for one pass
        for (NSString *identifier in @[@"builtin:classic", @"builtin:vinyl", @"builtin:messages"]) {
            renderAndCheck(identifier, data, cover, outDirectory, NO);
        }
        renderAndCheck(@"builtin:classic", data, cover, outDirectory, YES);

        // a style that does not exist fails with a reason, not a crash
        NSString *error = nil;
        CGImageRef none = SGCardRenderCG(@"builtin:absent", data, cover, 393, 852, 2, &error);
        check(!none && error.length, [NSString stringWithFormat:@"unknown style refused (%@)", error]);

        // the catalog styles the run put where the catalog keeps them
        NSArray<NSDictionary *> *styles = SGCCoreCatalogStyles();
        check(styles.count > 0, [NSString stringWithFormat:@"catalog styles found (%lu)", (unsigned long)styles.count]);
        NSInteger covered = 0;
        for (NSDictionary *style in styles) {
            NSString *identifier = style[@"id"];
            NSString *renderError = nil;
            CGImageRef image = SGCardRenderCG(identifier, data, cover, 393, 852, 2, &renderError);
            if (!image) {
                printf("FAIL  %@: %@\n", identifier.UTF8String, renderError.UTF8String ?: "no image");
                failures++;
                continue;
            }
            CGFloat share = inkShare(image);
            BOOL inked = share > 0.02;
            if (inked) covered++;
            printf("%s  %@ (%.1f%% ink, fonts %@)\n", inked ? "ok  " : "warn", identifier.UTF8String,
                   share * 100, [style[@"fonts"] componentsJoinedByString:@","].UTF8String);
            if (!inked) failures++;
            writePNG(image, [outDirectory stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"%@.png",
                              [identifier stringByReplacingOccurrencesOfString:@":" withString:@"-"]]]);
            CGImageRelease(image);
        }
        printf("     %ld catalog styles rendered, %ld with ink\n", (long)styles.count, (long)covered);

        CGImageRelease(cover);
        if (failures) printf("== %d checks failed\n", failures);
        else printf("== all checks passed\n");
    }
    return failures ? 1 : 0;
}
