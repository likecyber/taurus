#import "SGRShader.h"
#import "SGRShaderBuiltins.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "LyricsShaders/LyricsShaders.h"
#import "Settings/SGModPage.h"
#import "Shared/Catalog/SGCatalog.h"
#import <Metal/Metal.h>

NSNotificationName const SGRShaderDidChangeNotification = @"spotifyglass.redesign.visualizer.shaderDidChange";

// The compiled-in ones, in the order SGRShaderBuiltinSource hands their sources out.
typedef struct {
    NSString *__unsafe_unretained identifier, *name, *detail;
    NSInteger fps;
    CGFloat scale;
} SGRShaderBuiltin;

static const SGRShaderBuiltin kBuiltinShaders[] = {
    {@"builtin:bars", @"Bars", @"The spectrum as bars on a mirrored floor, a waveform running through them", 120, 0.8},
    {@"builtin:nebula", @"Nebula", @"A slow cloud of the cover's colours, stirred by the bass", 60, 0.5},
    {@"builtin:halo", @"Halo", @"The cover spinning like a record in a ring of sound", 120, 0.8},
};
enum { kBuiltinShaderCount = sizeof kBuiltinShaders / sizeof kBuiltinShaders[0] };

// The inputs a shader can name and the engine feeds today: its own last frame, the head's tilt, the
// typeset lyrics and their three-line text strip (Redesigned/Player/LyricsShaders), and the Canvas
// clip while its provider hands frames over.
static NSSet<NSString *> *fedInputs(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSSet setWithArray:@[@"previous", @"tilt", @"lyrics", @"text", @"clip",
                                                        @"artwork", @"audio", @"lineMap"]]; });
    return set;
}

@implementation SGRShaderInfo {
    NSDictionary *_entry;   // the catalog entry's JSON, nil for a compiled-in one
}

// The manifest's params arrive with the shader's own JSON, not the catalog's list, so the store
// adopts them when the source is first asked for.
- (void)adoptParams:(NSArray<NSDictionary *> *)params {
    if (params.count && !_params.count) _params = params;
}

- (void)adoptManifest:(NSDictionary *)manifest {
    if (![manifest isKindOfClass:NSDictionary.class]) return;
    [self adoptParams:[manifest[@"params"] isKindOfClass:NSArray.class] ? manifest[@"params"] : @[]];
    if ([manifest[@"backgroundScale"] isKindOfClass:NSNumber.class]) _scale = [manifest[@"backgroundScale"] doubleValue];
    if ([manifest[@"scale"] isKindOfClass:NSNumber.class]) _scale = [manifest[@"scale"] doubleValue];
}

- (instancetype)initWithBuiltin:(const SGRShaderBuiltin *)builtin {
    if (!(self = [super init])) return nil;
    _identifier = builtin->identifier;
    _name = builtin->name;
    _detail = builtin->detail;
    _author = @"";
    _fps = builtin->fps;
    _scale = builtin->scale;
    _builtin = YES;
    _uses = @[];
    _params = @[];
    return self;
}

- (instancetype)initWithCatalogEntry:(NSDictionary *)entry {
    if (!(self = [super init])) return nil;
    _entry = entry;
    NSString *id = [NSString stringWithFormat:@"cat:%@%@", entry[@"id"], entry[@"versionId"] ?: @""];
    _identifier = id;
    _name = [entry[@"name"] isKindOfClass:NSString.class] ? entry[@"name"] : @"Shader";
    _detail = [entry[@"description"] isKindOfClass:NSString.class] ? entry[@"description"] : @"";
    _author = [entry[@"author"] isKindOfClass:NSString.class] ? entry[@"author"] : @"";
    _fps = [entry[@"fps"] isKindOfClass:NSNumber.class] ? [entry[@"fps"] integerValue] : 60;
    _scale = [entry[@"scale"] isKindOfClass:NSNumber.class] ? [entry[@"scale"] doubleValue] : 0.5;
    _builtin = NO;
    _uses = [entry[@"uses"] isKindOfClass:NSArray.class] ? entry[@"uses"] : @[];
    BOOL fed = YES;
    for (NSString *use in _uses) if (![fedInputs() containsObject:use]) fed = NO;
    _supported = fed;
    // The manifest comes with the shader itself (SGRShaderLoadSource), so the list reads the entry's
    // own copy when the catalog carried one and answers empty until then.
    NSDictionary *manifest = entry[@"manifest"];
    _params = [manifest[@"params"] isKindOfClass:NSArray.class] ? manifest[@"params"] : @[];
    return self;
}

// Chroma's two built-in lyric-aware player shaders (Poster and Cut) use the lyric engine's
// frame ABI, but the downloadable lyrics-shaders catalog is a separate Lyrics surface.  Keep
// these two player shaders in this model without ever importing the lyrics catalog here.
- (instancetype)initWithLyricsInfo:(NSDictionary *)info {
    if (!(self = [super init])) return nil;
    NSString *identifier = [info[@"identifier"] isKindOfClass:NSString.class] ? info[@"identifier"] : nil;
    if (!identifier.length) return nil;
    _identifier = [identifier hasPrefix:@"cat:"] ? [@"lyr:" stringByAppendingString:identifier] : identifier;
    _name = [info[@"name"] isKindOfClass:NSString.class] ? info[@"name"] : @"Shader";
    _detail = [info[@"detail"] isKindOfClass:NSString.class] ? info[@"detail"] : @"";
    _author = [info[@"author"] isKindOfClass:NSString.class] ? info[@"author"] : @"";
    _fps = [info[@"fps"] isKindOfClass:NSNumber.class] ? [info[@"fps"] integerValue] : 60;
    _scale = [info[@"scale"] isKindOfClass:NSNumber.class] ? [info[@"scale"] doubleValue] : 0.5;
    _builtin = [info[@"builtin"] boolValue];
    _uses = [info[@"uses"] isKindOfClass:NSArray.class] ? info[@"uses"] : @[];
    BOOL fed = YES;
    for (NSString *use in _uses) if (![fedInputs() containsObject:use]) fed = NO;
    _supported = fed;
    _params = [info[@"params"] isKindOfClass:NSArray.class] ? info[@"params"] : @[];
    return self;
}

@end

#pragma mark - the list

// Main thread. The catalog's answers are merged in as they arrive; the objects are kept so a page
// holding one across a reload still compares equal.
static NSMutableArray<SGRShaderInfo *> *sg_builtins, *sg_catalog;
static id sg_lyricsObserver;

static NSMutableArray *builtinsList(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_builtins = [NSMutableArray array];
        for (NSUInteger i = 0; i < kBuiltinShaderCount; i++) [sg_builtins addObject:[[SGRShaderInfo alloc] initWithBuiltin:&kBuiltinShaders[i]]];
        sg_catalog = [NSMutableArray array];
    });
    return sg_builtins;
}

static void mergeCatalog(id json) {
    if (![json isKindOfClass:NSArray.class]) return;
    NSMutableArray *list = [NSMutableArray array];
    for (NSDictionary *entry in json) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        SGRShaderInfo *info = [[SGRShaderInfo alloc] initWithCatalogEntry:entry];
        if (!info.supported) continue;
        // The one already held wins, so a page's row keeps its object across refreshes.
        NSUInteger held = [sg_catalog indexOfObjectPassingTest:^BOOL(SGRShaderInfo *kept, NSUInteger _, BOOL *__) {
            return [kept.identifier isEqualToString:info.identifier];
        }];
        [list addObject:held != NSNotFound ? sg_catalog[held] : info];
    }
    sg_catalog = list;
}

NSArray<SGRShaderInfo *> *SGRShaders(void) {
    builtinsList();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGRShaderRefreshCatalog(); });
    // Only Chroma's two player shaders join this list.  Downloadable lyrics shaders are selected
    // from the Lyrics page and have a different line/background ABI.
    NSMutableArray *all = [sg_builtins mutableCopy];
    for (NSDictionary *info in SGRLyricsShaderInfos()) {
        NSString *identifier = info[@"identifier"];
        if (![identifier isEqualToString:@"builtin:poster"] && ![identifier isEqualToString:@"builtin:cut"]) continue;
        SGRShaderInfo *shader = [[SGRShaderInfo alloc] initWithLyricsInfo:info];
        if (shader.supported) [all addObject:shader];
    }
    [all addObjectsFromArray:sg_catalog];
    return all;
}

void SGRShaderRefreshCatalog(void) {
    builtinsList();
    SGCatalogFetch(@"shaders", ^(id json, NSError *error) {
        if (error) {
            SGLog(@"redesign visualizer: the catalog did not come (%@)", error.localizedDescription);
            return;
        }
        mergeCatalog(json);
        [[NSNotificationCenter defaultCenter] postNotificationName:SGRShaderDidChangeNotification object:nil];
    });
    // The lyrics engine fetches its own catalog; both answers come out of the one notification.
    if (!sg_lyricsObserver)
        sg_lyricsObserver = [NSNotificationCenter.defaultCenter addObserverForName:SGRLyricsShaderDidChangeNotification
                                                                             object:nil queue:nil usingBlock:^(NSNotification *_) {
            [[NSNotificationCenter defaultCenter] postNotificationName:SGRShaderDidChangeNotification object:nil];
        }];
}

#pragma mark - the choice

SGRShaderInfo *SGRShaderChosen(void) {
    NSString *identifier = [NSUserDefaults.standardUserDefaults stringForKey:SGRKeyVisualiserShader] ?: @"builtin:bars";
    for (SGRShaderInfo *shader in SGRShaders()) if ([shader.identifier isEqualToString:identifier]) return shader;
    return builtinsList().firstObject;
}

void SGRShaderChoose(SGRShaderInfo *shader) {
    if (!shader) return;
    [NSUserDefaults.standardUserDefaults setObject:shader.identifier forKey:SGRKeyVisualiserShader];
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRShaderDidChangeNotification object:nil];
}

BOOL SGRShaderMetalAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ available = MTLCreateSystemDefaultDevice() != nil; });
    return available;
}

#pragma mark - the source

void SGRShaderLoadSource(SGRShaderInfo *shader, void (^done)(NSString *)) {
    done = [done copy];
    if (!shader) return done(nil);
    if ([shader.identifier hasPrefix:@"builtin:bars"] || [shader.identifier hasPrefix:@"builtin:nebula"]
        || [shader.identifier hasPrefix:@"builtin:halo"])
        return done(SGRShaderBuiltinSource((NSInteger)[builtinsList() indexOfObject:shader]));
    // The lyrics engine's builtins and catalog entries (lyr:cat:…) load through its own loader; its
    // identifiers come back unprefixed.
    if ([shader.identifier hasPrefix:@"builtin:poster"] || [shader.identifier hasPrefix:@"builtin:cut"]
        || [shader.identifier hasPrefix:@"lyr:"]) {
        NSString *their = [shader.identifier hasPrefix:@"lyr:"] ? [shader.identifier substringFromIndex:4] : shader.identifier;
        return SGRLyricsShaderLoadSource(their, ^(NSString *source, NSDictionary *manifest) {
            [shader adoptManifest:manifest];
            done(source);
        });
    }
    // cat:<uuid>@<versionId>: the catalog keeps the shader's JSON under the uuid's name.
    NSString *uuid = [[shader.identifier substringFromIndex:4] componentsSeparatedByString:@"@"].firstObject;
    SGCatalogFile(@"shaders", [uuid stringByAppendingPathExtension:@"json"], 0, nil, ^(NSURL *file, NSError *error) {
        if (!file) return done(nil);
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:file] options:0 error:nil];
        NSDictionary *shaderJSON = [json[@"shader"] isKindOfClass:NSDictionary.class] ? json[@"shader"] : json;
        NSString *source = shaderJSON[@"msl"];
        if (![source isKindOfClass:NSString.class]) return done(nil);
        // The manifest travels with the source; the params are on the info from here on.
        NSDictionary *manifest = [shaderJSON[@"manifest"] isKindOfClass:NSDictionary.class] ? shaderJSON[@"manifest"] : nil;
        [shader adoptManifest:manifest];
        done(source);
    });
}

#pragma mark - the params

static NSMutableDictionary *storedParams(void) {
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:SGRKeyVisualiserShaderParams];
    NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSMutableDictionary.class, NSArray.class,
                       NSMutableArray.class, NSString.class, NSNumber.class, nil];
    NSMutableDictionary *all = data ? [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:nil] : nil;
    if (![all isKindOfClass:NSMutableDictionary.class]) all = [NSMutableDictionary dictionary];
    return all;
}

static void saveParams(NSMutableDictionary *all) {
    [NSUserDefaults.standardUserDefaults setObject:[NSKeyedArchiver archivedDataWithRootObject:all requiringSecureCoding:NO error:nil]
                                            forKey:SGRKeyVisualiserShaderParams];
}
static id defaultOf(NSDictionary *param) {
    id value = param[@"default"];
    if ([param[@"type"] isEqualToString:@"toggle"]) return @(value ? [value boolValue] : NO);
    if ([param[@"type"] isEqualToString:@"color"]) return [value isKindOfClass:NSString.class] ? value : @"#ffffff";
    return @(value ? [value doubleValue] : 0);
}

NSDictionary<NSString *, id> *SGRShaderParamValues(SGRShaderInfo *shader) {
    if (!shader) return @{};
    NSDictionary *set = storedParams()[shader.identifier] ?: @{};
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithCapacity:shader.params.count];
    for (NSDictionary *param in shader.params) {
        if (![param isKindOfClass:NSDictionary.class]) continue;
        id value = set[param[@"id"]] ?: defaultOf(param);
        values[param[@"id"]] = value;
    }
    return values;
}

id SGRShaderParamValue(SGRShaderInfo *shader, NSString *paramID) {
    return SGRShaderParamValues(shader)[paramID];
}

void SGRShaderSetParamValue(SGRShaderInfo *shader, NSString *paramID, id value) {
    if (!shader || !paramID.length || !value) return;
    NSMutableDictionary *all = storedParams();
    NSMutableDictionary *set = [all[shader.identifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    set[paramID] = value;
    all[shader.identifier] = set;
    saveParams(all);
    [[NSNotificationCenter defaultCenter] postNotificationName:SGRShaderDidChangeNotification object:nil];
}

#pragma mark - the Player page's pages

// A colour param's page: the system picker as a child of a page of ours, writing back as a hex string.
@interface SGRShaderColourPage : SGPage <UIColorPickerViewControllerDelegate>
- (instancetype)initWithShader:(SGRShaderInfo *)shader paramID:(NSString *)paramID;
@end

static NSString *SGRLocalizedLabel(SGRShaderInfo *shader, NSString *paramID);

@implementation SGRShaderColourPage {
    SGRShaderInfo *_shader;
    NSString *_paramID;
}

- (instancetype)initWithShader:(SGRShaderInfo *)shader paramID:(NSString *)paramID {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    _shader = shader;
    _paramID = paramID;
    self.title = SGRLocalizedLabel(shader, paramID) ?: paramID;
    return self;
}

// The label the manifest gave the param, or the id; a page of the mod's carries the title.
static NSString *SGRLocalizedLabel(SGRShaderInfo *shader, NSString *paramID) {
    for (NSDictionary *param in shader.params)
        if ([param[@"id"] isEqualToString:paramID]) return param[@"label"];
    return nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIColor *current = [self colourOf:SGRShaderParamValue(_shader, _paramID)];
    UIColorPickerViewController *picker = [UIColorPickerViewController new];
    picker.supportsAlpha = NO;
    picker.selectedColor = current;
    picker.title = self.title;
    picker.delegate = self;
    CGRect frame = self.view.bounds;
    frame.size.height = MIN(480, frame.size.height);
    picker.view.frame = frame;
    picker.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    picker.view.backgroundColor = UIColor.blackColor;
    [self addChildViewController:picker];
    [self.view addSubview:picker.view];
    [picker didMoveToParentViewController:self];
}

// Every colour the picker settles on, stored; the shader picks it up the next frame.
- (void)colorPickerViewControllerDidSelectColor:(UIColorPickerViewController *)picker {
    [self store:picker.selectedColor];
}

- (UIColor *)colourOf:(id)value {
    NSString *hex = [value isKindOfClass:NSString.class] ? value : @"#ffffff";
    hex = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (hex.length == 3) {
        NSMutableString *six = [NSMutableString string];
        for (NSUInteger i = 0; i < 3; i++) [six appendFormat:@"%c%c", [hex characterAtIndex:i], [hex characterAtIndex:i]];
        hex = six;
    }
    unsigned value6 = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&value6];
    return [UIColor colorWithRed:((value6 >> 16) & 0xff) / 255.0 green:((value6 >> 8) & 0xff) / 255.0
                            blue:(value6 & 0xff) / 255.0 alpha:1];
}

- (void)store:(UIColor *)colour {
    CGFloat red, green, blue, alpha;
    [colour getRed:&red green:&green blue:&blue alpha:&alpha];
    SGRShaderSetParamValue(_shader, _paramID, [NSString stringWithFormat:@"#%02x%02x%02x",
                                              (int)round(red * 255), (int)round(green * 255), (int)round(blue * 255)]);
}

@end

// The rows of one shader's params: a slider, a switch, or a colour page per value.
static NSArray<SGModRow *> *paramRows(SGRShaderInfo *shader) {
    NSDictionary<NSString *, id> *values = SGRShaderParamValues(shader);
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSDictionary *param in shader.params) {
        if (![param isKindOfClass:NSDictionary.class]) continue;
        NSString *identifier = [param[@"id"] isKindOfClass:NSString.class] ? param[@"id"] : nil;
        NSString *label = [param[@"label"] isKindOfClass:NSString.class] ? param[@"label"] : identifier;
        if (!identifier || !label.length) continue;
        NSString *type = [param[@"type"] isKindOfClass:NSString.class] ? param[@"type"] : @"float";
        SGModRow *row;
        if ([type isEqualToString:@"toggle"]) {
            // A switch row reads and writes a defaults key; the param has none of its own, so the row
            // carries a key that is seeded from the param store here and written back on toggle.
            row = SGOptionRow(label, nil, nil);
            row.key = [@"spotifyglass.redesign.visualizer.param." stringByAppendingString:identifier];
            [NSUserDefaults.standardUserDefaults setObject:@([values[identifier] boolValue]) forKey:row.key];
            row.changed = ^(BOOL on) { SGRShaderSetParamValue(shader, identifier, @(on)); };
        } else if ([type isEqualToString:@"colour"] || [type isEqualToString:@"color"]) {
            row = SGPageRow(label, ^UIViewController * { return [[SGRShaderColourPage alloc] initWithShader:shader paramID:identifier]; });
            row.value = ^NSString * { return SGRShaderParamValue(shader, identifier); };
        } else {
            double minimum = [param[@"min"] isKindOfClass:NSNumber.class] ? [param[@"min"] doubleValue] : 0;
            double maximum = [param[@"max"] isKindOfClass:NSNumber.class] ? [param[@"max"] doubleValue] : 1;
            double step = [param[@"step"] isKindOfClass:NSNumber.class] ? [param[@"step"] doubleValue] : 0.01;
            row = SGSliderRow(label, nil, minimum, maximum, step,
                              ^double { return [SGRShaderParamValue(shader, identifier) doubleValue]; },
                              ^(double value) { SGRShaderSetParamValue(shader, identifier, @(value)); },
                              ^NSString *(double value) { return [NSString stringWithFormat:@"%.2f", value]; });
        }
        [rows addObject:row];
    }
    return rows;
}

// The list: the compiled-in shaders, then the catalog's, the chosen one ticked. Picking one swaps the
// Visualizer's view under the field; the page reloads as the catalog arrives.
UIViewController *SGRShaderPickerPage(UIViewController *owner) {
    SGRShaderInfo *chosen = SGRShaderChosen();
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (SGRShaderInfo *shader in SGRShaders()) {
        NSString *subtitle = shader.author.length ? [NSString stringWithFormat:@"%@ · %@", shader.author, shader.detail ?: @""] : shader.detail;
        SGModRow *row = SGActionRow(shader.name, subtitle, ^{
            SGRShaderChoose(shader);
            [owner.navigationController popViewControllerAnimated:YES];
        });
        if ([shader.identifier isEqualToString:chosen.identifier]) row.symbol = @"checkmark";
        [rows addObject:row];
    }
    SGModRow *refresh = SGActionRow(@"Refresh catalog", @"Ask the catalog for its shaders again", ^{
        SGRShaderRefreshCatalog();
    });
    refresh.refreshOn = SGRShaderDidChangeNotification;
    [rows addObject:refresh];
    return [[SGModPage alloc] initWithTitle:@"Shader" intro:nil
                                          sections:@[SGNotedSection(nil, rows,
                                                                   @"The first three are built in. The rest come from the catalog and are "
                                                                   @"downloaded the first time they are drawn.")]
                                                                 footer:nil];
}

// The chosen shader's params, after its source has brought them in; until then the page says the
// shader is still coming and reloads when it is.
UIViewController *SGRShaderParamsPage(UIViewController *owner) {
    (void)owner;
    SGRShaderInfo *shader = SGRShaderChosen();
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    if (shader.params.count) {
        [rows addObjectsFromArray:paramRows(shader)];
    } else {
        SGModRow *waiting = SGStatRow(shader.name, ^NSString * { return @"No settings"; });
        waiting.subtitle = @"Its settings arrive with the shader itself; pull the picker down or reopen this page.";
        waiting.refreshOn = SGRShaderDidChangeNotification;
        [rows addObject:waiting];
    }
    return [[SGModPage alloc] initWithTitle:@"Shader settings" intro:nil
                                          sections:@[SGSection(nil, rows)] footer:nil];
}
