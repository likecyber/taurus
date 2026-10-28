// The pipeline's spine: the three builtin styles, the lockscreen catalog beside them, the
// chosen style id, the per-css sheet cache, and the render itself -- template and data to a
// tree, cascade and layout, the --fit search so the line fits its box, and the paint into a
// bitmap. Everything here is Core Graphics; the UIKit wrapper and the settings page sit on top.
#import "SGCardPrivate.h"
#import "Shared/Catalog/SGCatalog.h"
#import "Shared/Fonts/FontCatalog.h"

extern void SGLogMessage(NSString *message);
#define SGLog(fmt, ...) SGLogMessage([NSString stringWithFormat:(fmt), ##__VA_ARGS__])

NSNotificationName const SGLockCardStyleDidChangeNotification = @"spotifyglass.lockCard.style.changed";
NSString *const SGKeyLockCardStyle = @"spotifyglass.lockCard.style";

static NSString *const kKind = @"lockscreen";

#pragma mark - the builtins

NSDictionary *SGCCoreBuiltinStyles(void) {
    static NSDictionary *styles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        styles = @{
            @"builtin:classic": @{
                @"id": @"builtin:classic",
                @"name": @"Classic",
                @"author": @"",
                @"fonts": @[],
                @"template": SGCardDefaultTemplate(),
                @"css": @".bg { filter: blur(40px) saturate(1.5) brightness(.55); transform: scale(1.25); }\n"
                        @".card { display: flex; flex-direction: column; justify-content: center; gap: 4cqw; padding: var(--safe-top) 8cqw var(--safe-bottom); }\n"
                        @".meta, .prev, .tr { display: none }\n"
                        @".line { font: 700 calc(9cqw * var(--fit))/1.12 system-ui; text-shadow: 0 0 1.5cqw rgba(0, 0, 0, .3); text-wrap: balance; }\n"
                        @".next { font: 600 5cqw/1.2 system-ui; color: rgba(255, 255, 255, .45); }\n",
            },
            @"builtin:vinyl": @{
                @"id": @"builtin:vinyl",
                @"name": @"Vinyl",
                @"author": @"",
                @"fonts": @[ @"Instrument Serif" ],
                @"template": SGCardDefaultTemplate(),
                @"css": @".card { display: flex; flex-direction: column; align-items: center; gap: 2cqw; padding: calc(var(--safe-top) + 56cqw) 10cqw 0; text-align: center; background: #0e0e0e; }\n"
                        @".card::after { content: ''; position: absolute; z-index: 1; left: 25cqw; top: calc(var(--safe-top) + 4cqw); width: 50cqw; height: 50cqw; border-radius: 50%; background: repeating-radial-gradient(circle, #151515 0 .6cqw, #222 .6cqw 1cqw); }\n"
                        @".bg { inset: auto; z-index: 2; left: 40.5cqw; top: calc(var(--safe-top) + 19.5cqw); width: 19cqw; height: 19cqw; border-radius: 50%; }\n"
                        @".line { font: italic calc(8cqw * var(--fit))/1.05 'Instrument Serif', serif; text-wrap: balance }\n"
                        @".next { font: 4.6cqw/1.25 'Instrument Serif', serif; opacity: .45 }\n"
                        @".prev, .tr, .meta { display: none }\n",
            },
            @"builtin:messages": @{
                @"id": @"builtin:messages",
                @"name": @"Messages",
                @"author": @"",
                @"fonts": @[],
                @"template": SGCardDefaultTemplate(),
                @"css": @".card { display: flex; flex-direction: column; justify-content: flex-end; gap: 2cqw; padding: var(--safe-top) 5cqw var(--safe-bottom); background: #000; font: 5cqw/1.3 system-ui; }\n"
                        @".meta { align-self: center; margin-bottom: 1cqw; font-size: 3.4cqw; color: #8e8e93 }\n"
                        @".meta .artist::before { content: ' · ' }\n"
                        @".prev, .line, .next { max-width: 74%; padding: 2.4cqw 3.8cqw; border-radius: 5.5cqw }\n"
                        @".prev { align-self: flex-start; background: #262629; border-bottom-left-radius: 1.5cqw }\n"
                        @".line { align-self: flex-end; background: #2f5bff; border-bottom-right-radius: 1.5cqw }\n"
                        @".next { align-self: flex-start; font-size: 0; padding: 3cqw 4.4cqw }\n"
                        @".next::before { content: '• • •'; font-size: 4.4cqw; color: #8e8e93 }\n"
                        @".bg, .tr { display: none }\n",
            },
        };
    });
    return styles;
}

#pragma mark - the catalog

NSArray<NSDictionary *> *SGCCoreTakeCatalog(id json);

NSArray<NSDictionary *> *SGCCoreCatalogStyles(void) {
    static NSArray *styles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        styles = SGCCoreTakeCatalog(SGCatalogCached(kKind));
    });
    return styles;
}

NSArray<NSDictionary *> *SGCCoreTakeCatalog(id json) {
    if (![json isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *styles = [NSMutableArray array];
    for (id item in json) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *entry = [item isKindOfClass:[NSDictionary class]] && item[@"style"] ? item[@"style"] : item;
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : nil;
        NSString *css = [entry[@"css"] isKindOfClass:NSString.class] ? entry[@"css"] : nil;
        if (!identifier.length || !css.length || css.length > 64 * 1024) continue;
        NSMutableDictionary *style = [NSMutableDictionary dictionary];
        style[@"id"] = [@"catalog:" stringByAppendingString:identifier];
        NSString *entryName = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : nil;
        style[@"name"] = entryName.length ? entryName : identifier;
        style[@"author"] = [entry[@"author"] isKindOfClass:NSString.class] ? entry[@"author"] : @"";
        style[@"fonts"] = [entry[@"fonts"] isKindOfClass:NSArray.class] ? entry[@"fonts"] : @[];
        style[@"css"] = css;
        NSString *entryTemplate = [entry[@"template"] isKindOfClass:NSString.class] ? entry[@"template"] : nil;
        if (entryTemplate.length) style[@"template"] = entryTemplate;
        [styles addObject:style];
    }
    return styles;
}

void SGCCoreRefreshCatalog(void) {
    SGCatalogFetch(kKind, ^(id json, NSError *error) {
        if (error && error.code != 0)
            SGLog(@"lockcard: the styles catalog did not come: %@", error.localizedDescription);
    });
}

#pragma mark - the chosen style

NSString *SGCCoreStyleID(void) {
    NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyLockCardStyle];
    if (!identifier.length) identifier = @"builtin:classic";
    if (SGCCoreBuiltinStyles()[identifier]) return identifier;
    for (NSDictionary *entry in SGCCoreCatalogStyles())
        if ([entry[@"id"] isEqualToString:identifier]) return identifier;
    // an unknown id, a catalog entry that left, falls back rather than rendering nothing
    return @"builtin:classic";
}

void SGCCoreSetStyle(NSString *styleID) {
    if (!styleID.length) return;
    [NSUserDefaults.standardUserDefaults setObject:styleID forKey:SGKeyLockCardStyle];
    [[NSNotificationCenter defaultCenter] postNotificationName:SGLockCardStyleDidChangeNotification object:nil];
}

#pragma mark - the fonts of a style

// The catalog's entry class lives behind a UIKit header, so the two calls the engine needs
// come in as declarations; the entries answer download through the runtime.
@class SGFontCatalogEntry;
extern NSArray *SGFontCatalogEntries(void);

void SGCCoreRegisterFontsForStyle(NSString *styleID) {
    NSDictionary *style = SGCCoreBuiltinStyles()[styleID];
    if (!style) {
        for (NSDictionary *entry in SGCCoreCatalogStyles())
            if ([entry[@"id"] isEqualToString:styleID]) { style = entry; break; }
    }
    if (!style) return;
    SGFontCatalogRegisterInstalled();
    for (NSString *family in style[@"fonts"]) {
        if (![family isKindOfClass:NSString.class]) continue;
        if (SGFontCatalogHasFamily(family)) continue;
        // the entry's download is async; until it lands the render falls back to the next family
        for (SGFontCatalogEntry *entry in SGFontCatalogEntries())
            if ([entry.familyName caseInsensitiveCompare:family] == NSOrderedSame) {
                [entry download];
                break;
            }
    }
}

#pragma mark - the sheet cache

static NSCache<NSString *, NSArray<SGCRule *> *> *sheetCache(void) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSCache new];
        cache.countLimit = 32;
    });
    return cache;
}

static NSArray<SGCRule *> *sheetForCSS(NSString *css) {
    NSArray<SGCRule *> *sheet = [sheetCache() objectForKey:css];
    if (sheet) return sheet;
    sheet = SGCParseCSS(css, 1, 0);
    [sheetCache() setObject:sheet forKey:css];
    return sheet;
}

#pragma mark - the render

static NSDictionary *styleWithID(NSString *identifier) {
    NSDictionary *style = SGCCoreBuiltinStyles()[identifier];
    if (style) return style;
    for (NSDictionary *entry in SGCCoreCatalogStyles())
        if ([entry[@"id"] isEqualToString:identifier]) return entry;
    return nil;
}

// The lowest edge the tree's frames reach, absolute positions folded in on the way down.
static void extentOfBox(SGCBox *box, CGPoint offset, CGFloat *out) {
    CGPoint here = CGPointMake(offset.x + box.frame.origin.x, offset.y + box.frame.origin.y);
    *out = MAX(*out, here.y + box.frame.size.height);
    for (SGCBox *child in box.children) extentOfBox(child, here, out);
}

CGImageRef _Nullable SGCardRenderCG(NSString *styleID, NSDictionary *data, CGImageRef _Nullable cover,
                          CGFloat width, CGFloat height, CGFloat scale, NSString * _Nullable * _Nullable errorOut) {
    NSDictionary *style = styleWithID(styleID);
    if (!style) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"no style named %@", styleID ?: @""];
        return NULL;
    }
    if (!(width > 0) || !(height > 0)) {
        if (errorOut) *errorOut = @"the card needs a size";
        return NULL;
    }

    NSMutableArray<NSString *> *warnings = [NSMutableArray array];

    // the template: the style's own when it carries one, the shared one otherwise
    NSString *templateText = style[@"template"] ?: SGCardDefaultTemplate();
    NSString *html = SGCMustache(templateText, data ?: @{}, warnings);
    SGCBox *root = SGCParseHTML(html, warnings);

    // the sheets: the engine's own floor, then the style's, source order running across both
    NSMutableArray<SGCRule *> *rules = [NSMutableArray array];
    NSArray<SGCRule *> *floor = sheetForCSS(SGCardUserAgentCSS());
    [rules addObjectsFromArray:floor];
    NSInteger order = (NSInteger)floor.count;
    for (SGCRule *rule in sheetForCSS(style[@"css"])) {
        rule.order = order++;
        [rules addObject:rule];
    }

    SGCCtx *env = [SGCCtx new];
    env.cardW = width;
    env.cardH = height;
    env.scale = MAX(scale, 1);
    env.cover = cover;
    env.warnings = warnings;
    env.safeTop = [data[@"safeTop"] isKindOfClass:NSNumber.class] ? [data[@"safeTop"] doubleValue] : 59;
    env.safeBottom = [data[@"safeBottom"] isKindOfClass:NSNumber.class] ? [data[@"safeBottom"] doubleValue] : 34;

    // the seeds: safe areas in points, the cover marker, and the fit the loop below drives
    NSString *time = [data[@"time"] isKindOfClass:NSString.class] ? data[@"time"] : @"";
    NSArray *words = [data[@"words"] isKindOfClass:NSArray.class] ? data[@"words"] : @[];
    NSString *index = [data[@"index"] isKindOfClass:NSString.class] ? data[@"index"] : @"";
    NSString *count = [data[@"count"] isKindOfClass:NSString.class] ? data[@"count"] : @"";
    NSDictionary *seed = @{
        @"--safe-top": [NSString stringWithFormat:@"%@px", @(env.safeTop)],
        @"--safe-bottom": [NSString stringWithFormat:@"%@px", @(env.safeBottom)],
        @"--cover": @"cover",
        @"--fit": @"1",
        @"--index": index,
        @"--count": count,
        @"--words": [NSString stringWithFormat:@"%lu", (unsigned long)words.count],
        @"--chars": [NSString stringWithFormat:@"%lu", (unsigned long)time.length],
    };

    // cascade and layout, then the fit search: the largest --fit at 1 or below that keeps the
    // .line's text inside its box and the card's content inside the card, in at most three
    // passes. A centered flex column sizes the line to its text, so the card's extent is the
    // overflow signal that matters there.
    CGFloat fit = 1;
    for (int pass = 0; pass < 3; pass++) {
        NSMutableDictionary *vars = [seed mutableCopy];
        vars[@"--fit"] = [NSString stringWithFormat:@"%g", fit];
        SGCCascade(root, rules, vars, env);
        SGCLayoutTree(root, env);

        __block SGCBox *line = nil;
        [root walk:^(SGCBox *box, SGCBox *parent) {
            if (line || !box.style || box.style.display == SGCDisplayNone) return;
            if ([box.classList containsObject:@"line"]) line = box;
        }];
        if (!line || !line.textLines.count) break;
        CGFloat textHeight = SGCTextHeight(line);
        CGFloat inner = line.frame.size.height - line.style.padding.top - line.style.padding.bottom -
                        line.style.borderTop - line.style.borderBottom;
        CGFloat needed = textHeight - inner;   // how far the text runs past its own box
        if (needed < 0) needed = 0;

        // the card's whole content extent, in card coordinates
        CGFloat extent = 0;
        extentOfBox(root, CGPointZero, &extent);
        CGFloat pastCard = extent - height;
        if (pastCard > needed) needed = pastCard;
        if (needed <= 0.5) break;

        // text height scales with the fit, the wrap only helps: aim under and try again
        CGFloat target = textHeight - needed * (textHeight / MAX(textHeight, 1));
        CGFloat next = fit * MAX(target / MAX(textHeight, 1), 0.2) * 0.98;
        if (next < 0.25) next = 0.25;
        if (next >= fit - 0.001) break;
        fit = next;
    }

    // the bitmap
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, (size_t)ceil(width * scale), (size_t)ceil(height * scale),
                                             8, 0, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(space);
    if (!ctx) {
        if (errorOut) *errorOut = @"the bitmap would not be made";
        return NULL;
    }
    CGContextScaleCTM(ctx, scale, scale);
    CGImageRef image = NULL;
    @try {
        SGCPaintTree(root, ctx, env);
        image = CGBitmapContextCreateImage(ctx);
    } @catch (NSException *exception) {
        if (errorOut) *errorOut = [NSString stringWithFormat:@"the paint raised %@", exception.reason ?: exception.name];
    }
    CGContextRelease(ctx);

    if (warnings.count && image)
        SGLog(@"lockcard: %@, %lu warnings, first: %@", style[@"name"], (unsigned long)warnings.count, warnings.firstObject);
    if (!image && errorOut && !*errorOut) *errorOut = @"nothing was painted";
    return image;
}
