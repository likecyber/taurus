// The lyrics engine (LyricsShaders.h): the typesetter's output drawn onto Metal, the frame the
// linemap packs, and the store of what the user tuned. Three feeds come out of it, all drawn by
// the same linemap pass:
//
//   the strip    four rows of one line each -- the line before, the current, the next, the one
//                after -- what the styles sample at [[texture(5)]];
//   the text     three rows (before, current, next) for the shaders' `text` input;
//   the column   the window laid out in the style's column, for SGRLyricsShaderDraw's target.
//
// Each feed keeps two texture sets and bakes into the one the encoder is not reading, so the
// CPU refills while the GPU is still on the other. Rasters are baked on line changes and style
// changes only; the per-frame work is patching the lines' clock fields and one small encode.
//
// Threading: main thread only (the sound read excepted, which SGRSpectrum owns).
#import "LyricsShaders.h"
#import "SGRLyricsTypesetter.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRAccent.h"
#import "../SGRSpectrum.h"
#import "Shared/Catalog/SGCatalog.h"
#import "Shared/Fonts/FontCatalog.h"
#import "Shared/Player/PlayerState.h"

NSNotificationName const SGRLyricsShaderDidChangeNotification = @"spotifyglass.redesign.lyricsShaderDidChange";

#define SGRLyricsKeyParams @"spotifyglass.redesign.lyricsShader.params"
#define SGRLyricsKeyFavourites @"spotifyglass.redesign.lyricsShader.favourites"

// The strips: SGRLyricsStripRows rows of SGRLyricsRowEm pixels, the em box the shaders read a
// row as, and SGRLyricsStripWidth pixels across -- about ten em, enough for a lyric line before
// the row shrinks its glyphs to fit. The text rows are the same em box, three of them. The
// column's atlas is taller, one slab of every window line.
enum {
    SGRLyricsStripRows = 4,
    SGRLyricsTextRows = 3,
    SGRLyricsRowEm = 192,
    SGRLyricsStripWidth = 2048,
    SGRLyricsStripHeight = SGRLyricsStripRows * SGRLyricsRowEm,
    SGRLyricsTextHeight = SGRLyricsTextRows * SGRLyricsRowEm,
    SGRLyricsColumnHeight = 2048,
    SGRLyricsMaxLines = 8,           // per feed: the window plus a spare
    SGRLyricsLineDataWidth = 256,    // words across the line-data texture, the msl's clamp
    SGRLyricsMaxWords = 24,          // a strip row carries this many to the styles
};

// The em the typesetter measures at, in points. The row's em box is what the styles read, so
// SGRLyricsRowEm pixels over this many points is the strip rasters' density.
static const CGFloat SGRLyricsEm = 40.0;

// The compiled-in styles' fixed choices, read back by the typesetters and the frames.
typedef struct {
    NSString *__unsafe_unretained identifier, *name, *detail;
    CGFloat weight, tracking;     // the system font's weight, tracking in em
    BOOL uppercase;
    CGFloat anchor;               // the vertical share of the column the focus line sits on
    NSInteger before, after;      // the window the typesetter carries around the focus
    const char *sung, *unsung;    // hex, what the words fill with
} SGRLyricsBuiltinConfig;

static const SGRLyricsBuiltinConfig kConfigs[] = {
    {@"builtin:poster", @"Poster",
     @"A letterpress page the cover prints through, words set in heavy caps", 900, -0.01, YES,
     0.4, 1, 3, "#1ed760", "#ffffff"},
    {@"builtin:cut", @"Cut",
     @"Words cut out of the cover's own colour, the whole line or word by word", 800, 0, YES,
     0.5, 1, 2, "#ffffff", "#ffffff"},
};
enum { kConfigCount = sizeof kConfigs / sizeof kConfigs[0] };

// What the styles' frame tail needs of one strip row, kept by the bake.
typedef struct {
    float start, end, widthEm;
    NSInteger wordCount;
    float words[SGRLyricsMaxWords][4];   // x0, x1 in em, start, end in seconds
} StripRow;

// One baked feed: the two big textures and the per-line line-data textures of one parity, the
// draw records the linemap reads, and the fingerprint the next bake checks. The lines are slot
// indexed with NSNull where a row has nothing, so a record always sits on its own slot.
typedef struct {
    id<MTLTexture> glyph, word;
    id<MTLTexture> linedata[SGRLyricsMaxLines];
    SGRLyricsLineRec recs[SGRLyricsMaxLines];
    NSArray *lines;
    NSUInteger count;                    // slots the feed carries (rows, or the window's length)
    float aspect[4];                     // the text feed: advance over em per row
    StripRow rows[SGRLyricsStripRows];
    NSInteger baseIndex;                 // the window's first line index, -1 for none
    NSInteger focus;
    NSString *track;                     // what the bake was made of, to know when to redo it
    NSString *style;
    CGSize size;                         // the column's target when it was baked
    CGFloat pxPerPt;                     // the column's density, for the values it reports
} FeedSet;

enum { SGFeedStrip = 0, SGFeedText = 1, SGFeedColumn = 2, SGFeedCount = 3 };

#pragma mark - the engine's state

static id<MTLDevice> sg_device;
static id<MTLCommandQueue> sg_queue;
static id<MTLLibrary> sg_library;
static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *sg_pipelines;
static id<MTLLibrary> sg_catalogLibrary;
static id<MTLRenderPipelineState> sg_catalogLinePipeline, sg_catalogBackgroundPipeline;
static id<MTLTexture> sg_catalogLineMap;
static NSString *sg_catalogStyle;
static MTLPixelFormat sg_catalogFormat;
static id<MTLTexture> sg_targets[2];          // the strip's and the text's own targets
static id<MTLCommandBuffer> sg_lastBuffer;
static BOOL sg_metalTried, sg_visible;
static NSUInteger sg_frameIndex;
static NSInteger sg_baked[SGFeedCount];       // the parity each feed's encoder reads
static double sg_delta = 1.0 / 60.0;
static SGRLyricsFrameRec sg_frames[3];        // strip, text, column

static NSString *sg_style;                    // the chosen identifier, Poster until set
static NSString *sg_typesetKey;               // what the three typesetters were built for
static SGRLyricsTypesetter *sg_typesetters[SGFeedCount];

static NSArray<SGKaraokeLine *> *sg_sorted;   // the track's lines, in time order
static NSString *sg_track;
static uint32_t sg_seed;
static CFTimeInterval sg_trackChangedAt, sg_lastFrameAt;
static NSInteger sg_focus = -1;
static double sg_position;                    // seconds, the delay folded in

static FeedSet sg_sets[SGFeedCount][2];
static NSMutableArray<NSDictionary *> *sg_infos;

#pragma mark - the params

static NSMutableDictionary *storedParams(void) {
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:SGRLyricsKeyParams];
    NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSMutableDictionary.class, NSArray.class,
                       NSMutableArray.class, NSString.class, NSNumber.class, nil];
    NSMutableDictionary *all = data ? [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil] : nil;
    if (![all isKindOfClass:NSMutableDictionary.class]) all = [NSMutableDictionary dictionary];
    return all;
}

static void saveParams(NSMutableDictionary *all) {
    [NSUserDefaults.standardUserDefaults setObject:[NSKeyedArchiver archivedDataWithRootObject:all requiringSecureCoding:NO error:nil]
                                            forKey:SGRLyricsKeyParams];
}

static id defaultOf(NSDictionary *param) {
    id value = param[@"default"];
    if ([param[@"type"] isEqualToString:@"toggle"]) return @(value ? [value boolValue] : NO);
    if ([param[@"type"] isEqualToString:@"color"]) return [value isKindOfClass:NSString.class] ? value : @"#ffffff";
    return @(value ? [value doubleValue] : 0);
}

NSDictionary<NSString *, id> *SGRLyricsShaderParamValues(NSString *identifier) {
    if (!identifier.length) return @{};
    NSDictionary *info = nil;
    for (NSDictionary *candidate in SGRLyricsShaderInfos())
        if ([candidate[@"identifier"] isEqualToString:identifier]) info = candidate;
    NSDictionary *set = storedParams()[identifier] ?: @{};
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *param in info[@"params"]) {
        if (![param isKindOfClass:NSDictionary.class]) continue;
        NSString *paramID = [param[@"id"] isKindOfClass:NSString.class] ? param[@"id"] : nil;
        if (!paramID.length) continue;
        values[paramID] = set[paramID] ?: defaultOf(param);
    }
    return values;
}

void SGRLyricsShaderSetParamValue(NSString *identifier, NSString *paramID, id value) {
    if (!identifier.length || !paramID.length) return;
    NSMutableDictionary *all = storedParams();
    NSMutableDictionary *mine = [all[identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (value == nil) [mine removeObjectForKey:paramID];
    else mine[paramID] = value;
    all[identifier] = mine;
    saveParams(all);
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRLyricsShaderDidChangeNotification object:nil];
}

static NSString *catalogUUID(NSString *identifier) {
    if (![identifier hasPrefix:@"cat:"]) return nil;
    return [[identifier substringFromIndex:4] componentsSeparatedByString:@"@"].firstObject;
}

BOOL SGRLyricsShaderIsCatalogIdentifier(NSString *identifier) { return catalogUUID(identifier).length > 0; }

BOOL SGRLyricsShaderIsDownloaded(NSString *identifier) {
    NSString *uuid = catalogUUID(identifier);
    return uuid.length && SGCatalogHasFile(@"lyrics-shaders", [uuid stringByAppendingPathExtension:@"json"], 0, nil);
}

void SGRLyricsShaderDownload(NSString *identifier, void (^done)(NSError *error)) {
    NSString *uuid = catalogUUID(identifier);
    if (!uuid.length) return done ? done(nil) : (void)0;
    SGCatalogFile(@"lyrics-shaders", [uuid stringByAppendingPathExtension:@"json"], 0, nil, ^(NSURL *file, NSError *error) {
        if (done) done(error);
        if (file) [[NSNotificationCenter defaultCenter] postNotificationName:SGRLyricsShaderDidChangeNotification object:nil];
    });
}

void SGRLyricsShaderRemove(NSString *identifier) {
    NSString *uuid = catalogUUID(identifier);
    if (!uuid.length) return;
    SGCatalogRemoveFile(@"lyrics-shaders", [uuid stringByAppendingPathExtension:@"json"]);
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRLyricsShaderDidChangeNotification object:nil];
}

static NSMutableSet *favourites(void) {
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:SGRLyricsKeyFavourites];
    return [NSMutableSet setWithArray:[saved isKindOfClass:NSArray.class] ? saved : @[]];
}

BOOL SGRLyricsShaderIsFavourite(NSString *identifier) { return identifier.length && [favourites() containsObject:identifier]; }

void SGRLyricsShaderSetFavourite(NSString *identifier, BOOL favourite) {
    if (!identifier.length) return;
    NSMutableSet *set = favourites();
    if (favourite) [set addObject:identifier]; else [set removeObject:identifier];
    [NSUserDefaults.standardUserDefaults setObject:set.allObjects forKey:SGRLyricsKeyFavourites];
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRLyricsShaderDidChangeNotification object:nil];
}

// A hex colour over a fallback when it is not one, into the frame's floats.
static void colorInto(float *out, id value, float fallbackR, float fallbackG, float fallbackB) {
    NSString *hex = [value isKindOfClass:NSString.class] ? value : nil;
    if (hex.length < 3) {
        out[0] = fallbackR; out[1] = fallbackG; out[2] = fallbackB; out[3] = 1;
        return;
    }
    hex = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (hex.length == 3) {
        NSMutableString *six = [NSMutableString string];
        for (NSUInteger i = 0; i < 3; i++) [six appendFormat:@"%c%c", [hex characterAtIndex:i], [hex characterAtIndex:i]];
        hex = six;
    }
    unsigned parsed = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&parsed];
    if (hex.length == 8) parsed >>= 8;
    out[0] = ((parsed >> 16) & 0xff) / 255.0f;
    out[1] = ((parsed >> 8) & 0xff) / 255.0f;
    out[2] = (parsed & 0xff) / 255.0f;
    out[3] = 1;
}

#pragma mark - the infos

static NSArray<NSDictionary *> *posterCutParams(NSInteger which) {
    // The slots are the frame's param slots the sources read: a colour across three, a toggle
    // or a float on one, the packing the renderer flattens the params with.
    if (which == 0) return (@[
        @{@"id": @"halftone", @"label": @"Halftone", @"type": @"toggle", @"default": @YES, @"slot": @0},
        @{@"id": @"ink", @"label": @"Ink", @"type": @"color", @"default": @"#f4efe6", @"slot": @1},
        @{@"id": @"backdrop", @"label": @"Backdrop", @"type": @"float", @"min": @0, @"max": @1, @"default": @0.6, @"slot": @4},
        @{@"id": @"ghost", @"label": @"Ghost", @"type": @"float", @"min": @0, @"max": @0.5, @"default": @0.2, @"slot": @5},
    ]);
    return (@[
        @{@"id": @"ink", @"label": @"Ink", @"type": @"color", @"default": @"#ffffff", @"slot": @1},
        @{@"id": @"shade", @"label": @"Shade", @"type": @"float", @"min": @0, @"max": @1, @"default": @0.75, @"slot": @3},
        @{@"id": @"motion", @"label": @"Motion", @"type": @"float", @"min": @0, @"max": @1.5, @"default": @1, @"slot": @4},
        @{@"id": @"subtitle", @"label": @"Whole line", @"type": @"toggle", @"default": @YES, @"slot": @5},
    ]);
}

static NSDictionary *builtinInfo(NSInteger which) {
    const SGRLyricsBuiltinConfig *config = &kConfigs[which];
    return @{
        @"identifier": config->identifier,
        @"name": config->name,
        @"detail": [NSString stringWithUTF8String:config->detail],
        @"author": @"",
        @"fps": @60,
        @"scale": @0.65,
        @"uses": @[@"lyrics", @"clip"],
        @"params": posterCutParams(which),
        @"builtin": @YES,
        @"background": @NO,
    };
}

// The catalog's entries as the infos carry them, the manifest's params kept whole: what slots
// they name is the shader's own business, whoever renders the entry reads them off it.
static void mergeCatalog(id json) {
    if (![json isKindOfClass:NSArray.class]) return;
    NSMutableArray *list = [NSMutableArray array];
    for (NSInteger which = 0; which < kConfigCount; which++) [list addObject:builtinInfo(which)];
    for (NSDictionary *entry in json) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *entryID = [entry[@"id"] isKindOfClass:NSString.class] ? entry[@"id"] : nil;
        if (!entryID.length) continue;
        NSMutableArray *uses = [NSMutableArray array];
        for (NSString *use in entry[@"uses"]) {
            if ([use isKindOfClass:NSString.class]) [uses addObject:use];
        }
        [list addObject:@{
            @"identifier": [NSString stringWithFormat:@"cat:%@%@", entryID, entry[@"versionId"] ?: @""],
            @"name": [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"Shader",
            @"detail": [entry[@"description"] isKindOfClass:NSString.class] ? entry[@"description"] : @"",
            @"author": [entry[@"author"] isKindOfClass:NSString.class] ? entry[@"author"] : @"",
            @"fps": [entry[@"fps"] isKindOfClass:NSNumber.class] ? entry[@"fps"] : @60,
            @"scale": [entry[@"scale"] isKindOfClass:NSNumber.class] ? entry[@"scale"] : @0.65,
            @"uses": uses,
            @"params": @[],
            @"manifest": @{},
            @"builtin": @NO,
            @"background": @([entry[@"background"] boolValue]),
            @"family": [entry[@"family"] isKindOfClass:NSString.class] ? entry[@"family"] : @"",
        }];
    }
    sg_infos = list;
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRLyricsShaderDidChangeNotification object:nil];
}

NSArray<NSDictionary *> *SGRLyricsShaderInfos(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *list = [NSMutableArray array];
        for (NSInteger which = 0; which < kConfigCount; which++) [list addObject:builtinInfo(which)];
        sg_infos = list;
        SGCatalogFetch(@"lyrics-shaders", ^(id json, NSError *error) {
            if (error) {
                SGLog(@"redesign lyrics shaders: the catalog did not come (%@)", error.localizedDescription);
                return;
            }
            mergeCatalog(json);
        });
    });
    return sg_infos;
}

static void adoptManifest(NSString *identifier, NSDictionary *manifest) {
    if (!identifier.length || ![manifest isKindOfClass:NSDictionary.class]) return;
    NSMutableArray *updated = [sg_infos mutableCopy] ?: [NSMutableArray array];
    for (NSUInteger i = 0; i < updated.count; i++) {
        NSDictionary *held = updated[i];
        if (![held[@"identifier"] isEqualToString:identifier]) continue;
        NSMutableDictionary *info = [held mutableCopy];
        info[@"manifest"] = manifest;
        info[@"params"] = [manifest[@"params"] isKindOfClass:NSArray.class] ? manifest[@"params"] : @[];
        NSDictionary *font = [manifest[@"font"] isKindOfClass:NSDictionary.class] ? manifest[@"font"] : @{};
        if ([font[@"family"] isKindOfClass:NSString.class]) info[@"family"] = font[@"family"];
        if ([manifest[@"uses"] isKindOfClass:NSArray.class]) info[@"uses"] = manifest[@"uses"];
        if ([manifest[@"backgroundScale"] isKindOfClass:NSNumber.class]) info[@"scale"] = manifest[@"backgroundScale"];
        updated[i] = info;
        break;
    }
    sg_infos = updated;
    if ([sg_style isEqualToString:identifier]) sg_typesetKey = nil;
}

void SGRLyricsShaderLoadSource(NSString *identifier, void (^done)(NSString *msl, NSDictionary *manifest)) {
    done = [done copy];
    if (!identifier.length) return done(nil, nil);
    for (NSUInteger which = 0; which < kConfigCount; which++) {
        if (![kConfigs[which].identifier isEqualToString:identifier]) continue;
        return done(SGRLyricsBuiltinSource(which + 1), @{ @"params": posterCutParams(which) });
    }
    // cat:<uuid>@<versionId>: the catalog keeps the style's JSON under the uuid's name.
    NSString *uuid = catalogUUID(identifier);
    SGCatalogFile(@"lyrics-shaders", [uuid stringByAppendingPathExtension:@"json"], 0, nil, ^(NSURL *file, NSError *error) {
        if (!file) return done(nil, nil);
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:0 error:nil];
        NSDictionary *shader = [json[@"shader"] isKindOfClass:NSDictionary.class] ? json[@"shader"] : json;
        NSDictionary *manifest = [shader[@"manifest"] isKindOfClass:NSDictionary.class] ? shader[@"manifest"] : @{};
        adoptManifest(identifier, manifest);
        done([shader[@"msl"] isKindOfClass:NSString.class] ? shader[@"msl"] : nil, manifest);
    });
}

#pragma mark - the song's state

// Nil-safe: two nils are the same track, and messaging nil only ever answers NO.
static BOOL sameText(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

static double engineNow(void) {
    return MAX(0, (SGKaraokePositionMs() + SGKaraokeDelayMs()) / 1000.0);
}

static void updateSongState(void) {
    NSString *track = SGKaraokePlayingTrack();
    if (track != sg_track && !(track && sg_track && [track isEqualToString:sg_track])) {
        sg_track = track;
        sg_sorted = nil;
        sg_focus = -1;
        sg_trackChangedAt = CACurrentMediaTime();
        uint32_t hash = 2166136261u;
        for (NSUInteger i = 0; i < track.length; i++) {
            hash ^= (uint32_t)[track characterAtIndex:i];
            hash *= 16777619u;
        }
        sg_seed = hash;
        // Everything baked was of the old track; the fingerprints stop matching below.
        for (NSInteger feed = 0; feed < SGFeedCount; feed++)
            for (NSInteger parity = 0; parity < 2; parity++) sg_sets[feed][parity].track = nil;
    }
    if (!sg_sorted && track.length) {
        NSArray *kept = SGKaraokeLinesForTrack(track);
        if (kept) sg_sorted = [kept sortedArrayUsingComparator:^NSComparisonResult(SGKaraokeLine *a, SGKaraokeLine *b) {
            return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
        }];
    }
    sg_position = engineNow();
    NSInteger focus = -1;
    while (focus + 1 < (NSInteger)sg_sorted.count && sg_sorted[focus + 1].start <= sg_position * 1000) focus++;
    sg_focus = focus;
}

static SGKaraokeLine *lineAt(NSInteger index) {
    if (index < 0 || index >= (NSInteger)sg_sorted.count) return nil;
    return sg_sorted[index];
}

#pragma mark - the typesetters

static NSDictionary *styleInfo(NSString *identifier) {
    for (NSDictionary *info in SGRLyricsShaderInfos())
        if ([info[@"identifier"] isEqualToString:identifier]) return info;
    return nil;
}

// The style's font at a density: the compiled-in ones carry their own weight, case and
// tracking; a catalog entry asks for a family through the fonts catalog and otherwise takes the
// system at a bookish weight.
static SGRLyricsTypesetter *makeTypesetter(NSInteger feed, CGFloat texelsPerPoint, CGFloat rasterHeight, CGFloat fontScale) {
    NSInteger which = -1;
    for (NSUInteger i = 0; i < kConfigCount; i++)
        if ([kConfigs[i].identifier isEqualToString:sg_style]) which = (NSInteger)i;
    NSString *family = which >= 0 ? nil : styleInfo(sg_style)[@"family"];
    CGFloat weight = 800, tracking = 0;
    BOOL uppercase = NO, italic = NO;
    if (which >= 0) {
        weight = kConfigs[which].weight;
        tracking = kConfigs[which].tracking;
        uppercase = kConfigs[which].uppercase;
    } else {
        NSDictionary *font = styleInfo(sg_style)[@"manifest"][@"font"];
        if ([font[@"weight"] isKindOfClass:NSNumber.class]) weight = [font[@"weight"] doubleValue];
        if ([font[@"tracking"] isKindOfClass:NSNumber.class]) tracking = [font[@"tracking"] doubleValue];
        italic = [font[@"italic"] boolValue];
        uppercase = [font[@"case"] isEqualToString:@"upper"] || [font[@"case"] isEqualToString:@"uppercase"];
    }
    SGRLyricsTypesetter *typesetter = [[SGRLyricsTypesetter alloc] initWithFamily:family.length ? family : nil
                                                                           weight:weight italic:italic
                                                                        uppercase:uppercase tracking:tracking];
    typesetter.texelsPerPoint = texelsPerPoint;
    typesetter.rasterHeight = rasterHeight;
    NSNumber *size = styleInfo(sg_style)[@"manifest"][@"font"][@"size"];
    typesetter.fontScale = fontScale * ([size isKindOfClass:NSNumber.class] ? size.doubleValue : 1);
    if (feed == SGFeedColumn) typesetter.rasterHeight = 0;   // the column frames the glyphs itself
    return typesetter;
}

static void ensureTypesetters(void) {
    if (!sg_style) sg_style = kConfigs[0].identifier;
    NSDictionary *info = styleInfo(sg_style);
    NSString *key = [NSString stringWithFormat:@"%@|%@", sg_style, info[@"family"] ?: @""];
    if ([sg_typesetKey isEqualToString:key]) return;
    sg_typesetKey = key;
    for (NSInteger feed = 0; feed < SGFeedCount; feed++) {
        CGFloat density = feed == SGFeedColumn ? 2.0 : SGRLyricsRowEm / SGRLyricsEm;
        CGFloat rasterHeight = feed == SGFeedColumn ? 0 : SGRLyricsRowEm;
        sg_typesetters[feed] = makeTypesetter(feed, density, rasterHeight, 1);
    }
    // The rasters were of the old font; every feed bakes again.
    for (NSInteger feed = 0; feed < SGFeedCount; feed++)
        for (NSInteger parity = 0; parity < 2; parity++) sg_sets[feed][parity].style = nil;
}

#pragma mark - the Metal pieces

static void ensureMetal(void) {
    if (!sg_device || sg_metalTried) return;
    sg_metalTried = YES;
    NSError *error = nil;
    sg_library = [sg_device newLibraryWithSource:SGRLyricsBuiltinSource(0) options:nil error:&error];
    if (!sg_library) {
        SGLog(@"redesign lyrics shaders: the linemap did not compile (%@)", error.localizedDescription);
        return;
    }
    sg_pipelines = [NSMutableDictionary dictionary];

    // The strip and text glyph atlases and word maps are fixed; the column's are taller, one
    // slab of every window line. Both parities of everything, made once.
    MTLTextureDescriptor *glyph = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:SGRLyricsStripWidth height:SGRLyricsStripHeight mipmapped:NO];
    glyph.usage = MTLTextureUsageShaderRead;
    glyph.storageMode = MTLStorageModeShared;
    MTLTextureDescriptor *columnGlyph = [glyph copy];
    columnGlyph.height = SGRLyricsColumnHeight;
    MTLTextureDescriptor *textGlyph = [glyph copy];
    textGlyph.height = SGRLyricsTextHeight;

    MTLTextureDescriptor *words = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                                                                     width:SGRLyricsStripWidth height:SGRLyricsStripHeight mipmapped:NO];
    words.usage = MTLTextureUsageShaderRead;
    words.storageMode = MTLStorageModeShared;
    MTLTextureDescriptor *columnWords = [words copy];
    columnWords.height = SGRLyricsColumnHeight;
    MTLTextureDescriptor *textWords = [words copy];
    textWords.height = SGRLyricsTextHeight;

    MTLTextureDescriptor *lineData = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                         width:SGRLyricsLineDataWidth height:4 mipmapped:NO];
    lineData.usage = MTLTextureUsageShaderRead;
    lineData.storageMode = MTLStorageModeShared;

    struct { MTLTextureDescriptor *glyph, *words; NSUInteger height; } plans[SGFeedCount] = {
        {glyph, words, SGRLyricsStripHeight},
        {textGlyph, textWords, SGRLyricsTextHeight},
        {columnGlyph, columnWords, SGRLyricsColumnHeight},
    };
    for (NSInteger feed = 0; feed < SGFeedCount; feed++) {
        for (NSInteger parity = 0; parity < 2; parity++) {
            MTLTextureDescriptor *g = [plans[feed].glyph copy];
            g.height = (NSUInteger)plans[feed].height;
            sg_sets[feed][parity].glyph = [sg_device newTextureWithDescriptor:g];
            MTLTextureDescriptor *w = [plans[feed].words copy];
            w.height = (NSUInteger)plans[feed].height;
            sg_sets[feed][parity].word = [sg_device newTextureWithDescriptor:w];
            for (NSUInteger i = 0; i < SGRLyricsMaxLines; i++)
                sg_sets[feed][parity].linedata[i] = [sg_device newTextureWithDescriptor:lineData];
        }
    }

    MTLTextureDescriptor *target = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                       width:SGRLyricsStripWidth height:SGRLyricsStripHeight mipmapped:NO];
    target.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    target.storageMode = MTLStorageModePrivate;
    sg_targets[0] = [sg_device newTextureWithDescriptor:target];
    MTLTextureDescriptor *textTarget = [target copy];
    textTarget.height = SGRLyricsTextHeight;
    sg_targets[1] = [sg_device newTextureWithDescriptor:textTarget];
}

static id<MTLRenderPipelineState> pipelineFor(MTLPixelFormat format) {
    NSNumber *key = @(format);
    id<MTLRenderPipelineState> pipeline = sg_pipelines[key];
    if (pipeline || !sg_library) return pipeline;
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [sg_library newFunctionWithName:@"sgShaderLineVertex"];
    descriptor.fragmentFunction = [sg_library newFunctionWithName:@"sgShaderLineFragment"];
    descriptor.colorAttachments[0].pixelFormat = format;
    NSError *error = nil;
    pipeline = [sg_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) {
        SGLog(@"redesign lyrics shaders: the pipeline did not build (%@)", error.localizedDescription);
        return nil;
    }
    sg_pipelines[key] = pipeline;
    return pipeline;
}

BOOL SGRLyricsShaderBuildCatalogStyle(NSString *identifier, NSString *source, MTLPixelFormat format,
                                      NSString **failure) {
    if (!sg_device || !identifier.length || !source.length) {
        if (failure) *failure = @"The lyrics shader has no device, identifier or source.";
        return NO;
    }
    NSError *error = nil;
    id<MTLLibrary> library = [sg_device newLibraryWithSource:source options:nil error:&error];
    if (!library) {
        if (failure) *failure = error.localizedDescription ?: @"The Metal library did not build.";
        return NO;
    }
    id<MTLFunction> lineVertex = [library newFunctionWithName:@"sgShaderLineVertex"];
    id<MTLFunction> lineFragment = [library newFunctionWithName:@"sgShaderLineFragment"];
    id<MTLFunction> backgroundVertex = [library newFunctionWithName:@"sgShaderBackgroundVertex"];
    id<MTLFunction> backgroundFragment = [library newFunctionWithName:@"sgShaderBackgroundFragment"];
    if (!lineVertex || !lineFragment) {
        if (failure) *failure = @"The catalog style carries no line entry points.";
        return NO;
    }
    MTLRenderPipelineDescriptor *line = [MTLRenderPipelineDescriptor new];
    line.vertexFunction = lineVertex;
    line.fragmentFunction = lineFragment;
    line.colorAttachments[0].pixelFormat = format;
    line.colorAttachments[0].blendingEnabled = YES;
    line.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    line.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    line.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    line.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    id<MTLRenderPipelineState> linePipeline = [sg_device newRenderPipelineStateWithDescriptor:line error:&error];
    if (!linePipeline) {
        if (failure) *failure = error.localizedDescription ?: @"The lyrics line pipeline did not build.";
        return NO;
    }
    id<MTLRenderPipelineState> backgroundPipeline = nil;
    if (backgroundVertex && backgroundFragment) {
        MTLRenderPipelineDescriptor *background = [MTLRenderPipelineDescriptor new];
        background.vertexFunction = backgroundVertex;
        background.fragmentFunction = backgroundFragment;
        background.colorAttachments[0].pixelFormat = format;
        backgroundPipeline = [sg_device newRenderPipelineStateWithDescriptor:background error:&error];
        if (!backgroundPipeline) {
            if (failure) *failure = error.localizedDescription ?: @"The lyrics background pipeline did not build.";
            return NO;
        }
    }
    sg_catalogLibrary = library;
    sg_catalogLinePipeline = linePipeline;
    sg_catalogBackgroundPipeline = backgroundPipeline;
    sg_catalogStyle = identifier;
    sg_catalogFormat = format;
    sg_catalogLineMap = nil;
    return YES;
}

static id<MTLTexture> catalogLineMap(CGSize size) {
    NSUInteger width = MAX((NSUInteger)size.width, 2), height = MAX((NSUInteger)size.height, 2);
    if (sg_catalogLineMap.width == width && sg_catalogLineMap.height == height) return sg_catalogLineMap;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                         width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    sg_catalogLineMap = [sg_device newTextureWithDescriptor:descriptor];
    return sg_catalogLineMap;
}

#pragma mark - the bake

// One box blur, separable: what the atlas' second and third channels carry, the blur and the
// glow the styles grow their halos out of.
static void boxBlur(uint8_t *pixels, uint8_t *scratch, NSUInteger width, NSUInteger height, NSUInteger radius) {
    if (!radius) return;
    for (NSUInteger y = 0; y < height; y++) {
        uint8_t *row = pixels + y * width;
        NSUInteger sum = 0;
        for (NSUInteger x = 0; x <= radius && x < width; x++) sum += row[x];
        for (NSUInteger x = 0; x < width; x++) {
            scratch[x] = (uint8_t)MIN(sum / (2 * radius + 1), 255);
            sum += row[MIN(x + radius + 1, width - 1)];
            if (x >= radius) sum -= row[x - radius];
        }
        memcpy(row, scratch, width);
    }
    for (NSUInteger x = 0; x < width; x++) {
        NSUInteger sum = 0;
        for (NSUInteger y = 0; y <= radius && y < height; y++) sum += pixels[y * width + x];
        for (NSUInteger y = 0; y < height; y++) {
            scratch[y] = (uint8_t)MIN(sum / (2 * radius + 1), 255);
            sum += pixels[MIN(y + radius + 1, height - 1) * width + x];
            if (y >= radius) sum -= pixels[(y - radius) * width + x];
        }
        for (NSUInteger y = 0; y < height; y++) pixels[y * width + x] = scratch[y];
    }
}

// One typeset line into the feed's textures: the coverage as the atlas' ink with its blur and
// glow beside it, the word ids where the glyphs sit, and the line's words and rows in the
// line-data texels. `slabX`/`slabY` place the slab in the texture, in pixels.
static void uploadLine(FeedSet *set, NSUInteger slot, SGRLyricsTypesetLine *line,
                       float slabX, float slabY) {
    NSUInteger width, height, stride;
    const uint8_t *coverage = [line coverageWidth:&width height:&height stride:&stride];
    if (!coverage || !set->glyph || !set->word || !set->linedata[slot]) return;
    if (width > SGRLyricsStripWidth || slot >= SGRLyricsMaxLines) return;
    if ((NSUInteger)slabY + height > set->glyph.height) return;

    uint8_t *ink = malloc(width * height);
    uint8_t *blur = malloc(width * height);
    uint8_t *glow = malloc(width * height);
    uint8_t *rgba = malloc(width * height * 4);
    uint32_t *ids = malloc(width * height * 4);
    if (!ink || !blur || !glow || !rgba || !ids) {
        free(ink); free(blur); free(glow); free(rgba); free(ids);
        return;
    }
    for (NSUInteger y = 0; y < height; y++) memcpy(ink + y * width, coverage + y * stride, width);
    memcpy(blur, ink, width * height);
    boxBlur(blur, glow, width, height, 2);
    memcpy(glow, ink, width * height);
    boxBlur(glow, blur, width, height, 6);
    for (NSUInteger i = 0; i < width * height; i++) {
        rgba[i * 4 + 0] = ink[i];
        rgba[i * 4 + 1] = blur[i];
        rgba[i * 4 + 2] = glow[i];
        rgba[i * 4 + 3] = ink[i];
    }
    [set->glyph replaceRegion:MTLRegionMake2D((NSUInteger)slabX, (NSUInteger)slabY, width, height)
                  mipmapLevel:0 withBytes:rgba bytesPerRow:width * 4];

    // The word ids, where the glyphs are: 255 and up reads as no word. The two pixels of left
    // padding the raster drew with shift every x over.
    memset(ids, 0xff, width * height * 4);
    NSUInteger wordCount;
    const SGRLyricsWordRec *words = [line words:&wordCount];
    for (NSUInteger i = 0; i < wordCount; i++) {
        NSUInteger from = MIN(MAX((NSUInteger)(words[i].x0 + 2), (NSUInteger)0), width - 1);
        NSUInteger to = MIN(MAX((NSUInteger)(words[i].x1 + 2) + 1, from + 1), width);
        for (NSUInteger y = 0; y < height; y++)
            for (NSUInteger x = from; x < to; x++) ids[y * width + x] = (uint32_t)words[i].index;
    }
    [set->word replaceRegion:MTLRegionMake2D((NSUInteger)slabX, (NSUInteger)slabY, width, height)
                 mipmapLevel:0 withBytes:ids bytesPerRow:width * 4];

    // The line's words and rows in the line-data texels: words on the first two rows, the
    // wrapped row on the last two, all in the atlas' pixels, the space `p` is read in.
    NSUInteger rowCount;
    const SGRLyricsRowRec *rows = [line rows:&rowCount];
    float data[SGRLyricsLineDataWidth * 4];
    memset(data, 0, sizeof data);
    for (NSUInteger i = 0; i < MIN(wordCount, (NSUInteger)SGRLyricsLineDataWidth); i++) {
        data[0 * SGRLyricsLineDataWidth + i * 4 + 0] = slabX + words[i].x0 + 2;
        data[0 * SGRLyricsLineDataWidth + i * 4 + 1] = slabX + words[i].x1 + 2;
        data[0 * SGRLyricsLineDataWidth + i * 4 + 2] = words[i].start;
        data[0 * SGRLyricsLineDataWidth + i * 4 + 3] = words[i].end;
        data[1 * SGRLyricsLineDataWidth + i * 4 + 0] = (float)words[i].row;
        data[1 * SGRLyricsLineDataWidth + i * 4 + 1] = (float)words[i].part;
        data[1 * SGRLyricsLineDataWidth + i * 4 + 2] = (float)words[i].flags;
        data[1 * SGRLyricsLineDataWidth + i * 4 + 3] = (float)words[i].index;
    }
    for (NSUInteger j = 0; j < MIN(rowCount, (NSUInteger)SGRLyricsLineDataWidth); j++) {
        data[2 * SGRLyricsLineDataWidth + j * 4 + 0] = slabY + rows[j].top;
        data[2 * SGRLyricsLineDataWidth + j * 4 + 1] = rows[j].height;
        data[2 * SGRLyricsLineDataWidth + j * 4 + 2] = slabY + rows[j].baseline;
        data[2 * SGRLyricsLineDataWidth + j * 4 + 3] = (float)rows[j].part;
        data[3 * SGRLyricsLineDataWidth + j * 4 + 0] = slabX + rows[j].x0;
        data[3 * SGRLyricsLineDataWidth + j * 4 + 1] = slabX + rows[j].x1;
        data[3 * SGRLyricsLineDataWidth + j * 4 + 2] = (float)rows[j].firstWord;
        data[3 * SGRLyricsLineDataWidth + j * 4 + 3] = (float)rows[j].wordCount;
    }
    [set->linedata[slot] replaceRegion:MTLRegionMake2D(0, 0, SGRLyricsLineDataWidth, 4)
                           mipmapLevel:0 withBytes:data bytesPerRow:SGRLyricsLineDataWidth * 4];
    free(ink); free(blur); free(glow); free(rgba); free(ids);
}

// The record the linemap draws with, everything but the clock, which the frames patch.
static void fillRec(SGRLyricsLineRec *rec, SGRLyricsTypesetLine *line, NSInteger index, NSInteger focus,
                    CGFloat texelsPerPoint, float rectX, float rectY, float scale, float opacity,
                    float texX, float texY, float texW, float texH) {
    NSUInteger wordCount, rowCount;
    [line words:&wordCount];
    [line rows:&rowCount];
    NSUInteger slabHeight = 0;
    [line coverageWidth:NULL height:&slabHeight stride:NULL];
    CGFloat slabWidth = line.widthPt * texelsPerPoint + 4;
    memset(rec, 0, sizeof *rec);
    rec->rect = (vector_float4){rectX, rectY, (float)slabWidth * scale, (float)slabHeight * scale};
    rec->size = (vector_float2){(float)line.widthPt, (float)SGRLyricsEm};
    rec->scale = scale;
    rec->fade = 1;
    rec->texRect = (vector_float4){texX, texY, texW, texH};
    rec->texelsPerPoint = (float)texelsPerPoint;
    rec->em = (float)line.em;
    rec->index = (float)index;
    rec->distance = (float)ABS(index - focus);
    rec->state = index < focus ? 3 : (index == focus ? 2 : 1);
    rec->singing = index == focus ? 1 : 0;
    rec->opacity = opacity;
    rec->start = line.startMs / 1000.0f;
    rec->end = line.endMs / 1000.0f;
    rec->duration = MAX(rec->end - rec->start, 0.05f);
    rec->sungEnd = line.sungEndMs / 1000.0f;
    rec->seed = (float)(sg_seed ^ (uint32_t)index);
    NSString *align = styleInfo(sg_style)[@"manifest"][@"layout"][@"align"];
    rec->align = [align isEqualToString:@"start"] ? 0 : [align isEqualToString:@"end"] ? 1 : 0.5f;
    rec->wordCount = (float)wordCount;
    rec->rowCount = (float)rowCount;
    rec->lineTiming = line.timing == SGKaraokeTimingWords ? 2 : (line.timing == SGKaraokeTimingLine ? 1 : 0);
    rec->parts = 1;
    SGKaraokeLine *next = lineAt(index + 1), *prev = lineAt(index - 1);
    rec->nextStart = next ? next.start / 1000.0f : rec->end + 30;
    rec->prevEnd = prev ? MAX(prev.end, SGKaraokeSungEnd(prev)) / 1000.0f : rec->start - 30;
}

// One row of the strip or the text feed: the slab sits on the row whole, so the linemap draws
// it one to one onto the target. A line too wide for the row is typeset again smaller, inside
// the same em box, so the row keeps its height and the baseline the shaders read it at.
static SGRLyricsTypesetLine *bakeRow(FeedSet *set, NSUInteger slot, SGKaraokeLine *karaoke, NSInteger feed,
                                     NSInteger index, NSInteger focus) {
    SGRLyricsTypesetter *typesetter = sg_typesetters[feed];
    SGRLyricsTypesetLine *line = [typesetter typeset:@[karaoke]].firstObject;
    if (!line) return nil;
    CGFloat width = line.widthPt * typesetter.texelsPerPoint;
    if (width > SGRLyricsStripWidth - 8) {
        CGFloat shrink = (SGRLyricsStripWidth - 8) / width;
        typesetter = makeTypesetter(feed, typesetter.texelsPerPoint, SGRLyricsRowEm, shrink);
        line = [typesetter typeset:@[karaoke]].firstObject;
        if (!line) return nil;
    }
    float slabY = (float)(slot * SGRLyricsRowEm);
    uploadLine(set, slot, line, 0, slabY);
    fillRec(&set->recs[slot], line, index, focus, typesetter.texelsPerPoint,
            0, slabY, 1, 1, 0, slabY, (float)(line.widthPt * typesetter.texelsPerPoint + 4), SGRLyricsRowEm);
    return line;
}

static void bakeStripOrText(NSInteger feed) {
    NSInteger rows = feed == SGFeedStrip ? SGRLyricsStripRows : SGRLyricsTextRows;
    NSInteger base = sg_focus >= 0 ? sg_focus - 1 : -1;   // the line before is the window's head

    // The set the encoder reads first: when it is already this window, nothing to do.
    FeedSet *set = &sg_sets[feed][sg_baked[feed]];
    if (sameText(set->track, sg_track) && set->focus == sg_focus && sameText(set->style, sg_style)) return;

    // The other parity, then: current when it holds this window already, rewritten otherwise.
    NSInteger parity = sg_baked[feed] ^ 1;
    set = &sg_sets[feed][parity];
    if (sameText(set->track, sg_track) && set->focus == sg_focus && sameText(set->style, sg_style)) {
        sg_baked[feed] = parity;
        return;
    }

    set->count = rows;
    set->lines = [NSMutableArray array];
    set->baseIndex = base;
    set->focus = sg_focus;
    set->track = sg_track;
    set->style = sg_style;
    memset(set->aspect, 0, sizeof set->aspect);
    memset(set->rows, 0, sizeof set->rows);
    for (NSInteger slot = 0; slot < rows; slot++) {
        NSInteger index = base + slot;
        SGKaraokeLine *karaoke = lineAt(index);
        SGRLyricsTypesetLine *line = karaoke && sg_typesetters[feed] ? bakeRow(set, (NSUInteger)slot, karaoke, feed, index, sg_focus) : nil;
        if (!line) {
            [(NSMutableArray *)set->lines addObject:NSNull.null];
            memset(&set->recs[slot], 0, sizeof set->recs[slot]);
            continue;
        }
        [(NSMutableArray *)set->lines addObject:line];
        // What the styles' frame tail reads of the row, in em over the row's em box.
        StripRow *row = &set->rows[slot];
        NSUInteger wordCount;
        const SGRLyricsWordRec *words = [line words:&wordCount];
        row->start = line.startMs / 1000.0f;
        row->end = MAX(line.endMs, line.sungEndMs) / 1000.0f;
        row->widthEm = (float)(line.widthPt / SGRLyricsEm);
        row->wordCount = MIN((NSInteger)wordCount, SGRLyricsMaxWords);
        for (NSInteger i = 0; i < row->wordCount; i++) {
            row->words[i][0] = (words[i].x0 + 2) / (float)SGRLyricsRowEm;
            row->words[i][1] = (words[i].x1 + 2) / (float)SGRLyricsRowEm;
            row->words[i][2] = words[i].start;
            row->words[i][3] = words[i].end;
        }
        set->aspect[slot] = (float)((line.widthPt * (SGRLyricsRowEm / SGRLyricsEm) + 4) / SGRLyricsRowEm);
    }
    sg_baked[feed] = parity;
}

static void bakeColumn(CGSize size, NSDictionary *params) {
    NSInteger parity = sg_baked[SGFeedColumn] ^ 1;
    FeedSet *set = &sg_sets[SGFeedColumn][parity];
    if (sameText(set->track, sg_track) && set->focus == sg_focus &&
        sameText(set->style, sg_style) && CGSizeEqualToSize(set->size, size)) {
        sg_baked[SGFeedColumn] = parity;
        return;
    }

    UIEdgeInsets safe = [params[@"safeArea"] isKindOfClass:NSValue.class] ? [params[@"safeArea"] UIEdgeInsetsValue] : UIEdgeInsetsZero;
    CGRect columnRect = [params[@"column"] isKindOfClass:NSValue.class] ? [params[@"column"] CGRectValue] : CGRectZero;
    CGFloat pxPerPt = [params[@"pxPerPt"] isKindOfClass:NSNumber.class] ? [params[@"pxPerPt"] doubleValue] : 3.0;
    CGFloat viewW = size.width / pxPerPt, viewH = size.height / pxPerPt;
    CGFloat anchor = 0.45;
    NSInteger before = 1, after = 3;
    for (NSUInteger i = 0; i < kConfigCount; i++)
        if ([kConfigs[i].identifier isEqualToString:sg_style]) {
            anchor = kConfigs[i].anchor;
            before = kConfigs[i].before;
            after = kConfigs[i].after;
        }
    if (CGRectIsEmpty(columnRect)) {
        CGFloat x = MAX(safe.left, 24);
        columnRect = CGRectMake(x, safe.top + viewH * 0.08, MAX(viewW - 2 * x, 40), viewH * 0.62);
    }
    NSDictionary *manifest = styleInfo(sg_style)[@"manifest"];
    NSDictionary *font = [manifest[@"font"] isKindOfClass:NSDictionary.class] ? manifest[@"font"] : @{};
    NSDictionary *layout = [manifest[@"layout"] isKindOfClass:NSDictionary.class] ? manifest[@"layout"] : @{};
    CGFloat emPt = MIN(MAX(columnRect.size.width / 7.0, 18), 46);
    CGFloat lineHeightFactor = [font[@"lineHeight"] isKindOfClass:NSNumber.class] ? [font[@"lineHeight"] doubleValue] : 1.2;
    CGFloat spacing = [layout[@"spacing"] isKindOfClass:NSNumber.class] ? [layout[@"spacing"] doubleValue] : 1;
    CGFloat lineHeight = emPt * lineHeightFactor * spacing * pxPerPt;
    CGFloat focusCenter = columnRect.origin.y + anchor * columnRect.size.height;

    set->count = 0;
    set->lines = [NSMutableArray array];
    set->baseIndex = sg_focus - before;
    set->focus = sg_focus;
    set->track = sg_track;
    set->style = sg_style;
    set->size = size;
    set->pxPerPt = pxPerPt;
    if (sg_focus < 0 || !sg_typesetters[SGFeedColumn] || !set->glyph) {
        sg_baked[SGFeedColumn] = parity;
        return;
    }

    SGRLyricsTypesetter *typesetter = sg_typesetters[SGFeedColumn];
    NSUInteger slot = 0;
    CGFloat slabY = 0;
    for (NSInteger index = set->baseIndex; index <= sg_focus + after; index++) {
        if (slot >= SGRLyricsMaxLines || slabY >= SGRLyricsColumnHeight - SGRLyricsRowEm) break;
        SGKaraokeLine *karaoke = lineAt(index);
        if (!karaoke) continue;
        SGRLyricsTypesetLine *line = [typesetter typeset:@[karaoke]].firstObject;
        if (!line) continue;
        CGFloat fit = MIN(1.0, (columnRect.size.width - 16) / MAX(line.widthPt, 1));
        CGFloat scale = pxPerPt * fit / typesetter.texelsPerPoint;
        CGFloat slabW = line.widthPt * typesetter.texelsPerPoint + 4;
        NSUInteger slabH = 0;
        [line coverageWidth:NULL height:&slabH stride:NULL];
        if ((NSUInteger)slabY + slabH > SGRLyricsColumnHeight) break;
        uploadLine(set, slot, line, 0, (float)slabY);
        CGFloat distance = ABS(index - sg_focus);
        CGFloat centerY = focusCenter + (index - sg_focus) * lineHeight;
        CGFloat rectW = slabW * scale, rectH = slabH * scale;
        CGFloat opacity = MAX(1 - 0.3 * distance, 0.16);
        fillRec(&set->recs[slot], line, index, sg_focus, typesetter.texelsPerPoint,
                (float)((columnRect.origin.x + columnRect.size.width / 2) * pxPerPt - rectW / 2),
                (float)(centerY * pxPerPt - rectH / 2), (float)scale, (float)opacity,
                0, (float)slabY, (float)slabW, (float)slabH);
        [(NSMutableArray *)set->lines addObject:line];
        slot++;
        slabY += slabH + 2;
    }
    set->count = slot;
    sg_baked[SGFeedColumn] = parity;
}

#pragma mark - the frames

// The frame's per-frame numbers, the same whatever the feed: the clock, the sound's few bands,
// the colours, and the layout's shares.
static void fillFrame(SGRLyricsFrameRec *frame, CGSize pixels, CGFloat pxPerPt, NSDictionary *params,
                      CGFloat emPt, BOOL background) {
    memset(frame, 0, sizeof *frame);
    frame->resolution = (vector_float2){(float)pixels.width, (float)pixels.height};
    frame->viewSize = frame->resolution;
    frame->pixelRatio = (float)pxPerPt;
    CFTimeInterval now = CACurrentMediaTime();
    frame->time = (float)now;
    frame->deltaTime = (float)MIN(MAX(sg_delta, 0), 0.5);
    frame->frameIndex = (uint32_t)sg_frameIndex;
    frame->position = (float)sg_position;
    SPTPlayerState *state = SGPlayerState();
    frame->duration = state ? (float)state.duration : 0;
    frame->progress = frame->duration > 0 ? frame->position / frame->duration : 0;
    frame->playing = state && !state.isPaused ? 1 : 0;
    frame->rate = state ? (float)state.playbackSpeed : 1;
    frame->sinceTrackChange = (float)(now - sg_trackChangedAt);
    frame->trackSeed = (float)sg_seed;
    frame->lineCount = (float)sg_sorted.count;
    frame->focusLine = (float)MAX(sg_focus, 0);
    frame->focus = sg_focus >= 0 ? 1 : 0;
    frame->timing = sg_focus >= 0 && lineAt(sg_focus).timing == SGKaraokeTimingWords ? 1 : 0;
    SGKaraokeLine *focusLine = lineAt(sg_focus);
    if (focusLine) {
        frame->sinceLineChange = MAX((float)(sg_position - focusLine.start / 1000.0), 0);
        SGKaraokeLine *next = lineAt(sg_focus + 1);
        frame->nextLineIn = next ? (float)MAX(next.start / 1000.0 - sg_position, 0) : 999;
    }
    frame->reduceMotion = UIAccessibilityIsReduceMotionEnabled() ? 1 : 0;

    NSString *sung = @"#1ed760", *unsung = @"#ffffff";
    CGFloat anchor = 0.45;
    for (NSUInteger i = 0; i < kConfigCount; i++)
        if ([kConfigs[i].identifier isEqualToString:sg_style]) {
            sung = @(kConfigs[i].sung);
            unsung = @(kConfigs[i].unsung);
            anchor = kConfigs[i].anchor;
        }
    float accent[4] = {0.12f, 0.84f, 0.38f, 1};
    UIColor *accentColor = SGRAccentColor() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1];
    CGFloat red, green, blue, alpha;
    if ([accentColor getRed:&red green:&green blue:&blue alpha:&alpha]) {
        accent[0] = (float)red; accent[1] = (float)green; accent[2] = (float)blue;
    }
    for (NSInteger c = 0; c < 4; c++) frame->accent[c] = accent[c];
    colorInto(frame->color0, nil, accent[0], accent[1], accent[2]);
    colorInto(frame->color1, sung, 1, 1, 1);
    colorInto(frame->color2, unsung, 1, 1, 1);
    colorInto(frame->sungColor, sung, 1, 1, 1);
    colorInto(frame->unsungColor, unsung, 1, 1, 1);
    frame->key[0] = frame->color0;
    frame->key[1] = frame->color1;
    frame->key[2] = frame->color2;
    frame->dim = 0.55f;
    frame->fade = 0.45f;
    frame->lowPower = [NSProcessInfo processInfo].lowPowerModeEnabled ? 1 : 0;
    frame->backgroundOn = background ? 1 : 0;
    NSNumber *backgroundScale = styleInfo(sg_style)[@"manifest"][@"backgroundScale"];
    frame->backgroundScale = [backgroundScale isKindOfClass:NSNumber.class] ? backgroundScale.floatValue : 1;
    frame->artworkReady = 1;
    frame->em = (float)emPt;
    frame->landscape = pixels.width > pixels.height ? 1 : 0;

    // The style's own values, a slot at a time, a colour across the three floats its slot names.
    float slots[16] = {0};
    NSDictionary *values = SGRLyricsShaderParamValues(sg_style);
    for (NSDictionary *param in styleInfo(sg_style)[@"params"]) {
        if (![param isKindOfClass:NSDictionary.class]) continue;
        NSInteger slot = [param[@"slot"] isKindOfClass:NSNumber.class] ? [param[@"slot"] integerValue] : -1;
        if (slot < 0 || slot >= 16) continue;
        NSString *type = [param[@"type"] isKindOfClass:NSString.class] ? param[@"type"] : @"float";
        id value = values[param[@"id"]];
        if ([type isEqualToString:@"color"]) {
            float colour[4];
            colorInto(colour, value, 1, 1, 1);
            for (NSInteger channel = 0; channel < 3 && slot + channel < 16; channel++) slots[slot + channel] = colour[channel];
        } else if ([type isEqualToString:@"toggle"]) {
            slots[slot] = [value boolValue] ? 1 : 0;
        } else {
            slots[slot] = (float)[value doubleValue];
        }
    }
    for (NSInteger row = 0; row < 4; row++)
        frame->paramSlots[row] = (vector_float4){slots[row * 4], slots[row * 4 + 1], slots[row * 4 + 2], slots[row * 4 + 3]};

    // The sound's handful: the bands into level and thirds, the rest of the beat work stays
    // with whoever feeds the whole spectrum.
    float bands[SGRSpectrumBands];
    SGRSpectrumRead(bands);
    float sum = 0, low = 0, middle = 0, high = 0;
    for (NSInteger band = 0; band < SGRSpectrumBands; band++) {
        float value = MIN(MAX((bands[band] + 0.6f * band + 50) / 50, 0), 1);
        sum += value;
        if (band < SGRSpectrumBands / 3) low += value;
        else if (band < 2 * SGRSpectrumBands / 3) middle += value;
        else high += value;
    }
    frame->level = sum / SGRSpectrumBands;
    frame->bass = low / (SGRSpectrumBands / 3);
    frame->mid = middle / (SGRSpectrumBands / 3);
    frame->treble = high / (SGRSpectrumBands - 2 * (SGRSpectrumBands / 3));
    frame->energy = frame->level;
    frame->brightness = frame->treble;

    // The sight lines: the window's lines, in points, for the styles that draw marks where the
    // lines sit. The sight rects stay empty; nothing in the linemap reads them.
    FeedSet *column = &sg_sets[SGFeedColumn][sg_baked[SGFeedColumn]];
    CGFloat columnPxPerPt = column->pxPerPt > 0 ? column->pxPerPt : 3.0;
    NSInteger sight = 0;
    for (NSUInteger i = 0; i < column->count && sight < 16; i++) {
        SGRLyricsLineRec *rec = &column->recs[i];
        frame->sightLines[sight++] = (vector_float4){rec->rect.x / columnPxPerPt, rec->rect.y / columnPxPerPt,
                                                     rec->rect.z / columnPxPerPt, rec->rect.w / columnPxPerPt};
    }
    frame->sightCount = (float)sight;

    if ([params[@"column"] isKindOfClass:NSValue.class]) {
        CGRect columnRect = [params[@"column"] CGRectValue];
        frame->column = (vector_float4){(float)columnRect.origin.x, (float)columnRect.origin.y,
                                        (float)columnRect.size.width, (float)columnRect.size.height};
    } else {
        CGFloat viewW = pixels.width / pxPerPt, viewH = pixels.height / pxPerPt;
        UIEdgeInsets safe = [params[@"safeArea"] isKindOfClass:NSValue.class] ? [params[@"safeArea"] UIEdgeInsetsValue] : UIEdgeInsetsZero;
        frame->column = (vector_float4){(float)MAX(safe.left, 24), (float)(viewH * 0.08),
                                        (float)MAX(viewW - 2 * MAX(safe.left, 24), 40), (float)(viewH * 0.62)};
    }
    frame->anchor = (float)anchor;
}

// The clock on every line of a feed, after its bake: what the words sweep against.
static void patchFeed(FeedSet *set, double now) {
    for (NSUInteger i = 0; i < set->count && i < SGRLyricsMaxLines; i++) {
        if (![set->lines[i] isKindOfClass:SGRLyricsTypesetLine.class]) continue;
        SGRLyricsLineRec *rec = &set->recs[i];
        SGRLyricsTypesetLine *line = set->lines[i];
        rec->now = (float)now;
        rec->progress = MIN(MAX((now - rec->start) / MAX(rec->end - rec->start, 0.05), 0), 1);
        rec->singing = now >= rec->start && now <= rec->sungEnd ? 1 : 0;
        rec->activeWord = -1;
        NSUInteger wordCount;
        const SGRLyricsWordRec *words = [line words:&wordCount];
        for (NSUInteger w = 0; w < wordCount; w++)
            if (now >= words[w].start && now < words[w].end) rec->activeWord = (float)w;
    }
}

#pragma mark - the draw

static void encodeFeed(id<MTLCommandBuffer> buffer, id<MTLTexture> target, SGRLyricsFrameRec *frame, FeedSet *set) {
    id<MTLRenderPipelineState> pipeline = pipelineFor(target.pixelFormat);
    if (!pipeline) return;
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *colour = pass.colorAttachments[0];
    colour.texture = target;
    colour.loadAction = MTLLoadActionClear;
    colour.storeAction = MTLStoreActionStore;
    colour.clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:frame length:sizeof *frame atIndex:0];
    [encoder setFragmentBytes:frame length:sizeof *frame atIndex:0];
    for (NSUInteger i = 0; i < set->count && i < SGRLyricsMaxLines; i++) {
        if (![set->lines[i] isKindOfClass:SGRLyricsTypesetLine.class]) continue;
        [encoder setVertexBytes:&set->recs[i] length:sizeof set->recs[i] atIndex:1];
        [encoder setFragmentBytes:&set->recs[i] length:sizeof set->recs[i] atIndex:1];
        [encoder setFragmentTexture:set->glyph atIndex:0];
        [encoder setFragmentTexture:set->word atIndex:1];
        [encoder setFragmentTexture:set->linedata[i] atIndex:2];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexCount:4];
    }
    [encoder endEncoding];
}

#pragma mark - the public API

void SGRLyricsShaderUseDevice(id<MTLDevice> device, id<MTLCommandQueue> queue) {
    if (device && device != sg_device) {
        sg_device = device;
        sg_queue = queue;
        sg_metalTried = NO;
        sg_catalogLibrary = nil;
        sg_catalogLinePipeline = nil;
        sg_catalogBackgroundPipeline = nil;
        sg_catalogLineMap = nil;
        sg_catalogStyle = nil;
    } else if (queue) {
        sg_queue = queue;
    }
}

void SGRLyricsShaderSetStyle(NSString *identifier) {
    if (!identifier.length || sameText(sg_style, identifier)) return;
    sg_style = identifier;
    sg_typesetKey = nil;   // the typesetters and every bake follow the style
    for (NSInteger feed = 0; feed < SGFeedCount; feed++)
        for (NSInteger parity = 0; parity < 2; parity++) sg_sets[feed][parity].style = nil;
}

NSString *SGRLyricsShaderStyle(void) {
    return sg_style ?: kConfigs[0].identifier;
}

void SGRLyricsShaderSetVisible(BOOL visible) {
    sg_visible = visible;
}

void SGRLyricsShaderUpdate(void) {
    if (!sg_visible) return;
    ensureTypesetters();
    updateSongState();
    CFTimeInterval now = CACurrentMediaTime();
    sg_delta = sg_lastFrameAt ? now - sg_lastFrameAt : 1.0 / 60.0;
    sg_lastFrameAt = now;

    // One of the engine's own buffers in flight at a time: the last one is scheduled long
    // before this frame's CPU writes land on the other parity.
    [sg_lastBuffer waitUntilScheduled];

    if (sg_device) ensureMetal();   // before the bakes: the uploads need their textures
    bakeStripOrText(SGFeedStrip);
    bakeStripOrText(SGFeedText);
    patchFeed(&sg_sets[SGFeedStrip][sg_baked[SGFeedStrip]], sg_position);
    patchFeed(&sg_sets[SGFeedText][sg_baked[SGFeedText]], sg_position);
    fillFrame(&sg_frames[0], CGSizeMake(SGRLyricsStripWidth, SGRLyricsStripHeight), SGRLyricsRowEm / SGRLyricsEm,
              nil, SGRLyricsEm, NO);
    fillFrame(&sg_frames[1], CGSizeMake(SGRLyricsStripWidth, SGRLyricsTextHeight), SGRLyricsRowEm / SGRLyricsEm,
              nil, SGRLyricsEm, NO);

    sg_frameIndex++;
    if (!sg_device || !sg_library) return;
    id<MTLCommandBuffer> buffer = [sg_queue commandBuffer];
    encodeFeed(buffer, sg_targets[0], &sg_frames[0], &sg_sets[SGFeedStrip][sg_baked[SGFeedStrip]]);
    encodeFeed(buffer, sg_targets[1], &sg_frames[1], &sg_sets[SGFeedText][sg_baked[SGFeedText]]);
    [buffer commit];
    sg_lastBuffer = buffer;
}

void SGRLyricsShaderDraw(id<MTLCommandBuffer> buffer, id<MTLTexture> intoTexture, CGSize size,
                         NSDictionary *params) {
    if (!buffer || !intoTexture || !sg_device) return;
    ensureTypesetters();
    updateSongState();
    ensureMetal();
    if (!sg_library) return;
    [sg_lastBuffer waitUntilScheduled];
    bakeColumn(size, params ?: @{});
    patchFeed(&sg_sets[SGFeedColumn][sg_baked[SGFeedColumn]], sg_position);
    CGFloat pxPerPt = [params[@"pxPerPt"] isKindOfClass:NSNumber.class] ? [params[@"pxPerPt"] doubleValue] : 3.0;
    fillFrame(&sg_frames[2], size, pxPerPt, params, SGRLyricsEm, NO);
    encodeFeed(buffer, intoTexture, &sg_frames[2], &sg_sets[SGFeedColumn][sg_baked[SGFeedColumn]]);
}

void SGRLyricsShaderDrawCatalogStyle(id<MTLCommandBuffer> buffer, id<MTLTexture> target, CGSize size,
                                     id<MTLTexture> artwork, id<MTLTexture> sound,
                                     id<MTLTexture> previous) {
    if (!buffer || !target || !sg_catalogLinePipeline || ![sg_catalogStyle isEqualToString:sg_style] ||
        target.pixelFormat != sg_catalogFormat) return;
    ensureTypesetters();
    updateSongState();
    ensureMetal();
    if (!sg_library) return;
    NSDictionary *params = @{ @"pxPerPt": @3.0 };
    bakeColumn(size, params);
    FeedSet *set = &sg_sets[SGFeedColumn][sg_baked[SGFeedColumn]];
    patchFeed(set, sg_position);
    BOOL background = [styleInfo(sg_style)[@"background"] boolValue];
    fillFrame(&sg_frames[2], size, 3.0, params, SGRLyricsEm, background);
    sg_frames[2].artworkReady = artwork ? 1 : 0;
    sg_frames[2].heard = sound ? 1 : 0;

    id<MTLTexture> lineMap = catalogLineMap(size);
    if (lineMap) encodeFeed(buffer, lineMap, &sg_frames[2], set);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    MTLRenderPassColorAttachmentDescriptor *colour = pass.colorAttachments[0];
    colour.texture = target;
    colour.loadAction = MTLLoadActionClear;
    colour.storeAction = MTLStoreActionStore;
    colour.clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (background && sg_catalogBackgroundPipeline) {
        [encoder setRenderPipelineState:sg_catalogBackgroundPipeline];
        [encoder setVertexBytes:&sg_frames[2] length:sizeof sg_frames[2] atIndex:0];
        [encoder setFragmentBytes:&sg_frames[2] length:sizeof sg_frames[2] atIndex:0];
        [encoder setFragmentTexture:sound ?: artwork atIndex:3];
        [encoder setFragmentTexture:artwork ?: sound atIndex:4];
        [encoder setFragmentTexture:previous ?: sound ?: artwork atIndex:5];
        [encoder setFragmentTexture:lineMap ?: sound ?: artwork atIndex:6];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [encoder setRenderPipelineState:sg_catalogLinePipeline];
    [encoder setVertexBytes:&sg_frames[2] length:sizeof sg_frames[2] atIndex:0];
    [encoder setFragmentBytes:&sg_frames[2] length:sizeof sg_frames[2] atIndex:0];
    for (NSUInteger i = 0; i < set->count && i < SGRLyricsMaxLines; i++) {
        if (![set->lines[i] isKindOfClass:SGRLyricsTypesetLine.class]) continue;
        [encoder setVertexBytes:&set->recs[i] length:sizeof set->recs[i] atIndex:1];
        [encoder setFragmentBytes:&set->recs[i] length:sizeof set->recs[i] atIndex:1];
        [encoder setFragmentTexture:set->glyph atIndex:0];
        [encoder setFragmentTexture:set->word atIndex:1];
        [encoder setFragmentTexture:set->linedata[i] atIndex:2];
        [encoder setFragmentTexture:sound ?: artwork atIndex:3];
        [encoder setFragmentTexture:artwork ?: sound atIndex:4];
        [encoder setFragmentTexture:previous ?: sound ?: artwork atIndex:5];
        [encoder setFragmentTexture:lineMap ?: sound ?: artwork atIndex:6];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
}

id<MTLTexture> SGRLyricsShaderLyricsTexture(void) {
    return sg_targets[0];
}

id<MTLTexture> SGRLyricsShaderTextTexture(void) {
    return sg_targets[1];
}

void SGRLyricsShaderTextAspect(float out[4]) {
    FeedSet *set = &sg_sets[SGFeedText][sg_baked[SGFeedText]];
    if (out) {
        out[0] = set->aspect[0];
        out[1] = set->aspect[1];
        out[2] = set->aspect[2];
        out[3] = 1;
    }
}

BOOL SGRLyricsShaderTextReady(void) {
    FeedSet *set = &sg_sets[SGFeedText][sg_baked[SGFeedText]];
    return sg_targets[1] != nil && set->count > 0 && set->focus >= 0;
}

void SGRLyricsShaderFillStyleFrame(void *frame, size_t size) {
    if (!frame) return;
    FeedSet *set = &sg_sets[SGFeedStrip][sg_baked[SGFeedStrip]];
    BOOL ready = set->focus >= 0 && set->count > 0;
    NSInteger index = MAX(set->focus, 0);
    float *tail = (float *)((char *)frame + SGRLyricsStyleFrameTail);
    size_t room = size > SGRLyricsStyleFrameTail ? size - SGRLyricsStyleFrameTail : 0;
    if (room < sizeof(float) * 4) return;
    tail[0] = ready ? 1 : 0;          // lyricsReady
    tail[1] = ready && lineAt(index) && lineAt(index).timing == SGKaraokeTimingWords ? 1 : 0;   // lyricsTiming
    tail[2] = (float)index;           // lyricIndex
    tail[3] = (float)sg_sorted.count; // lyricCount
    if (room >= SGRLyricsStyleFrameLyricLines - SGRLyricsStyleFrameTail + sizeof(float) * 16) {
        float *lines = (float *)((char *)frame + SGRLyricsStyleFrameLyricLines);
        for (NSInteger row = 0; row < SGRLyricsStripRows; row++) {
            StripRow *strip = &set->rows[row];
            lines[row * 4 + 0] = strip->start;
            lines[row * 4 + 1] = strip->end;
            lines[row * 4 + 2] = strip->widthEm;
            lines[row * 4 + 3] = (float)strip->wordCount;
        }
    }
    if (room >= SGRLyricsStyleFrameLyricWords - SGRLyricsStyleFrameTail + sizeof(float) * 96 * 4) {
        float *words = (float *)((char *)frame + SGRLyricsStyleFrameLyricWords);
        for (NSInteger row = 0; row < SGRLyricsStripRows; row++)
            for (NSInteger i = 0; i < SGRLyricsMaxWords; i++) {
                float *into = words + (row * SGRLyricsMaxWords + i) * 4;
                NSInteger count = set->rows[row].wordCount;
                if (i < count) {
                    into[0] = set->rows[row].words[i][0];
                    into[1] = set->rows[row].words[i][1];
                    into[2] = set->rows[row].words[i][2];
                    into[3] = set->rows[row].words[i][3];
                } else {
                    into[0] = into[1] = into[2] = into[3] = 0;
                }
            }
    }
}
