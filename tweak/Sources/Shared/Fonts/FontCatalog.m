// The fonts of the catalog (Shared/Catalog) beside the files a user imports (FontImport.m): an entry's
// files are fetched one by one, each checked against its size and SHA-256 by the catalog API before it
// is kept, then the family is read from them and registered with Core Text for this process the same
// way an import is, and its id kept so the files register again at the next launches. A downloaded font
// is chosen like a family iOS carries, so everything Fonts.x does to a family it does to this one too.
// Everything here runs on the main queue, the catalog API's callbacks included.
#import <CoreText/CoreText.h>
#import "Core/SGCore.h"
#import "Shared/Catalog/SGCatalog.h"
#import "Shared/Fonts/FontCatalog.h"
#import "Shared/Fonts/Fonts.h"

NSNotificationName const SGFontCatalogDidChangeNotification = @"spotifyglass.font.catalog.didChange";
NSString *const SGFontCatalogEntryKey = @"entry";
NSString *const SGFontCatalogErrorKey = @"error";

@class SGFontCatalogDownload;

static NSMutableArray<SGFontCatalogEntry *> *sg_entries;   // nil until the first ask, so the objects stay stable
static NSMutableDictionary<NSString *, SGFontCatalogDownload *> *sg_downloads;   // the entries on their way
static NSMutableDictionary<NSString *, NSError *> *sg_errors;   // why an entry's last download failed

static void post(SGFontCatalogEntry *entry, NSError *error);

static void ensureMaps(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_downloads = [NSMutableDictionary dictionary];
        sg_errors = [NSMutableDictionary dictionary];
    });
}

static NSArray<NSString *> *installedIDs(void) {
    NSArray *ids = [NSUserDefaults.standardUserDefaults arrayForKey:SGKeyFontCatalogInstalled];
    return [ids isKindOfClass:NSArray.class] ? ids : @[];
}

static NSDictionary<NSString *, NSString *> *storedFamilies(void) {
    NSDictionary *families = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyFontCatalogFamilies];
    return [families isKindOfClass:NSDictionary.class] ? families : @{};
}

static NSString *stringIn(NSDictionary *json, NSString *key) {
    return [json[key] isKindOfClass:NSString.class] ? json[key] : nil;
}

// The path of one file of an entry under the fonts kind, the shape the catalog keeps them in.
static NSString *pathOf(NSString *identifier, NSString *name) {
    return [identifier stringByAppendingPathComponent:name];
}

static BOOL fontFile(NSString *name) {
    NSString *kind = name.pathExtension.lowercaseString;
    return [kind isEqualToString:@"ttf"] || [kind isEqualToString:@"otf"]
        || [kind isEqualToString:@"ttc"] || [kind isEqualToString:@"otc"];
}

// The one family all the files carry, read the way an import reads the files it picked, or nil.
static NSString *familyRead(NSArray<NSURL *> *urls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in urls) {
        NSArray *faces = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
        for (id face in faces)
            [names addObject:CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)face, kCTFontFamilyNameAttribute)) ?: @""];
    }
    return SGFontSingleFamily(names);
}

static void post(SGFontCatalogEntry *entry, NSError *error) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (entry) userInfo[SGFontCatalogEntryKey] = entry;
    userInfo[SGFontCatalogErrorKey] = error ?: NSNull.null;
    [[NSNotificationCenter defaultCenter] postNotificationName:SGFontCatalogDidChangeNotification
                                                        object:nil
                                                      userInfo:userInfo];
}

@interface SGFontCatalogDownload : NSObject
@property (nonatomic) NSInteger remaining;   // the files still out
@property (nonatomic) int64_t doneBytes, totalBytes;
@end

@implementation SGFontCatalogDownload
@end

@interface SGFontCatalogEntry ()
// Read out in the header; the class extension lets these synthesize.
@property (nonatomic, copy) NSString *identifier, *name, *familyName, *designer, *category, *styles, *license;
@property (nonatomic, copy) NSArray<NSDictionary *> *files;
@property (nonatomic, copy) NSDictionary *preview;
+ (SGFontCatalogEntry *)entryWithJSON:(NSDictionary *)json;
@end

@implementation SGFontCatalogEntry

+ (SGFontCatalogEntry *)entryWithJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    return [[self alloc] initWithJSON:json];
}

- (instancetype)initWithJSON:(NSDictionary *)json {
    if (!(self = [super init])) return nil;
    _identifier = stringIn(json, @"id");
    _familyName = stringIn(json, @"family");
    _name = stringIn(json, @"name") ?: _familyName;
    _designer = stringIn(json, @"designer");
    _category = stringIn(json, @"category");
    _styles = stringIn(json, @"styles");
    _license = stringIn(json, @"license");
    _preview = [json[@"preview"] isKindOfClass:NSDictionary.class] ? json[@"preview"] : nil;
    if (!_identifier.length || !_familyName.length) return nil;
    NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
    for (id item in [json[@"files"] isKindOfClass:NSArray.class] ? json[@"files"] : @[]) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *name = stringIn(item, @"name");
        NSNumber *size = [item[@"size"] isKindOfClass:NSNumber.class] ? item[@"size"] : nil;
        if (!name.length || !size) continue;
        NSMutableDictionary *file = [@{@"name": name, @"size": size} mutableCopy];
        if ([item[@"sha256"] isKindOfClass:NSString.class]) file[@"sha256"] = item[@"sha256"];
        [files addObject:file];
    }
    if (!files.count) return nil;
    _files = files;
    return self;
}

- (int64_t)downloadSize {
    int64_t total = 0;
    for (NSDictionary *file in _files) total += [file[@"size"] longLongValue];
    return total;
}

- (SGFontCatalogState)state {
    ensureMaps();
    if (sg_downloads[self.identifier]) return SGFontCatalogDownloading;
    // the ids kept say a download finished; the files are checked anyway, so a copy broken since does not count
    if (![installedIDs() containsObject:self.identifier]) return SGFontCatalogAbsent;
    for (NSDictionary *file in self.files)
        if (!SGCatalogHasFile(@"fonts", pathOf(self.identifier, file[@"name"]), [file[@"size"] longLongValue], file[@"sha256"]))
            return SGFontCatalogAbsent;
    return SGFontCatalogInstalled;
}

- (double)progress {
    ensureMaps();
    SGFontCatalogDownload *record = sg_downloads[self.identifier];
    if (record) return record.totalBytes > 0 ? MIN(1, (double)record.doneBytes / record.totalBytes) : 0.5;
    return self.state == SGFontCatalogInstalled ? 1 : 0;
}

- (NSError *)error {
    ensureMaps();
    return sg_errors[self.identifier];
}

- (NSURL *)licenseURL {
    for (NSDictionary *file in self.files)
        if ([file[@"name"] isEqualToString:@"OFL.txt"]) {
            NSURL *url = [SGCatalogFolder(@"fonts") URLByAppendingPathComponent:pathOf(self.identifier, @"OFL.txt")];
            return [NSFileManager.defaultManager fileExistsAtPath:url.path] ? url : nil;
        }
    return nil;
}

- (void)download {
    ensureMaps();
    if (self.state != SGFontCatalogAbsent) return;
    sg_errors[self.identifier] = nil;
    SGFontCatalogDownload *record = [SGFontCatalogDownload new];
    record.remaining = self.files.count;
    record.totalBytes = self.downloadSize;
    sg_downloads[self.identifier] = record;
    post(self, nil);
    for (NSDictionary *file in self.files) {
        NSString *name = file[@"name"];
        int64_t size = [file[@"size"] longLongValue];
        SGCatalogFile(@"fonts", pathOf(self.identifier, name), size, file[@"sha256"],
            ^(NSURL *url, NSError *error) { [self cameInBytes:size url:url error:error]; });
    }
}

// One file of the entry on disk or refused; the catalog API hands this over on the main queue.
- (void)cameInBytes:(int64_t)size url:(NSURL *)url error:(NSError *)error {
    SGFontCatalogDownload *record = sg_downloads[self.identifier];
    if (!record) {
        // the entry was removed or failed while this file was out: nothing of it stays behind
        if (url) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
            [NSFileManager.defaultManager removeItemAtURL:[SGCatalogFolder(@"fonts") URLByAppendingPathComponent:self.identifier] error:nil];
        }
        return;
    }
    if (error) return [self failed:error];
    record.remaining--;
    if (size > 0) record.doneBytes += size;
    if (record.remaining > 0) return post(self, nil);
    [self finished];
}

- (void)failed:(NSError *)error {
    sg_downloads[self.identifier] = nil;
    sg_errors[self.identifier] = error;
    [NSFileManager.defaultManager removeItemAtURL:[SGCatalogFolder(@"fonts") URLByAppendingPathComponent:self.identifier] error:nil];
    post(self, error);
}

- (void)finished {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSURL *folder = [SGCatalogFolder(@"fonts") URLByAppendingPathComponent:self.identifier];
    for (NSDictionary *file in self.files)
        if (fontFile(file[@"name"])) [urls addObject:[folder URLByAppendingPathComponent:file[@"name"]]];
    NSString *family = familyRead(urls);
    if (!family) {
        [self failed:[NSError errorWithDomain:@"spotifyglass.font" code:1
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ came in, but Core Text reads no single family from it.", self.name]}]];
        return;
    }
    for (NSURL *url in urls) {
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
            // a face already there is refused and there all the same, as with an import
            NSError *failure = CFBridgingRelease(error);
            SGLog(@"fonts: %@ not registered: %@", url.lastPathComponent, failure.localizedDescription);
        }
    }
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSMutableArray *ids = [installedIDs() mutableCopy];
    if (![ids containsObject:self.identifier]) [ids addObject:self.identifier];
    [store setObject:ids forKey:SGKeyFontCatalogInstalled];
    NSMutableDictionary *families = [storedFamilies() mutableCopy];
    families[self.identifier] = family;
    [store setObject:families forKey:SGKeyFontCatalogFamilies];
    sg_downloads[self.identifier] = nil;
    sg_errors[self.identifier] = nil;
    post(self, nil);
    SGLog(@"fonts: %@ downloaded, its family %@ in place for the next launches", self.name, family);
}

- (void)remove {
    ensureMaps();
    if (self.state == SGFontCatalogAbsent && !sg_errors[self.identifier]) return;
    sg_downloads[self.identifier] = nil;
    sg_errors[self.identifier] = nil;
    NSURL *folder = [SGCatalogFolder(@"fonts") URLByAppendingPathComponent:self.identifier];
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil] ?: @[])
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
    [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSMutableArray *ids = [installedIDs() mutableCopy];
    [ids removeObject:self.identifier];
    [store setObject:ids forKey:SGKeyFontCatalogInstalled];
    NSMutableDictionary *families = [storedFamilies() mutableCopy];
    [families removeObjectForKey:self.identifier];
    [store setObject:families forKey:SGKeyFontCatalogFamilies];
    // Default comes back if the family was the choice, as an import's delete does
    if (SGAppFontChosen() == SGAppFontFamily && [[store stringForKey:SGKeyAppFontFamily] isEqualToString:self.familyName])
        SGSetInt(SGKeyAppFont, SGAppFontSpotify);
    post(self, nil);
}

@end

static SGFontCatalogEntry *entryFor(NSString *identifier) {
    for (SGFontCatalogEntry *entry in sg_entries)
        if ([entry.identifier isEqualToString:identifier]) return entry;
    return nil;
}

// The catalog's JSON becomes the entries, the objects already out kept so a page holding one keeps it.
static void takeCatalog(NSArray *json) {
    if (!sg_entries) sg_entries = [NSMutableArray array];
    NSMutableArray<SGFontCatalogEntry *> *fresh = [NSMutableArray array];
    for (NSDictionary *item in json) {
        SGFontCatalogEntry *entry = [SGFontCatalogEntry entryWithJSON:item];
        if (!entry) continue;
        SGFontCatalogEntry *known = entryFor(entry.identifier);
        [fresh addObject:known ?: entry];
    }
    // a font on this iPhone that the catalog has dropped stays listed, so it can still be removed
    for (SGFontCatalogEntry *entry in sg_entries)
        if (![fresh containsObject:entry] && entry.state != SGFontCatalogAbsent) [fresh addObject:entry];
    sg_entries = fresh;
}

NSArray<SGFontCatalogEntry *> *SGFontCatalogEntries(void) {
    if (!sg_entries) {
        sg_entries = [NSMutableArray array];
        id cached = SGCatalogCached(@"fonts");
        if ([cached isKindOfClass:NSArray.class]) takeCatalog(cached);
        static dispatch_once_t once;
        dispatch_once(&once, ^{ SGFontCatalogRefresh(); });
    }
    return sg_entries;
}

void SGFontCatalogRefresh(void) {
    SGCatalogFetch(@"fonts", ^(id json, NSError *error) {
        if ([json isKindOfClass:NSArray.class]) takeCatalog(json);
        post(nil, error);
    });
}

void SGFontCatalogRegisterInstalled(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSMutableArray *kept = [NSMutableArray array];
        NSMutableDictionary *families = [storedFamilies() mutableCopy];
        for (NSString *identifier in installedIDs()) {
            NSURL *folder = [SGCatalogFolder(@"fonts") URLByAppendingPathComponent:identifier];
            NSArray<NSURL *> *items = [files contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil] ?: @[];
            if (!items.count) {
                // gone from disk, a restored backup or a reinstall: the id is forgotten and the entry shows as not downloaded
                [families removeObjectForKey:identifier];
                continue;
            }
            [kept addObject:identifier];
            for (NSURL *url in items) {
                if (!fontFile(url.lastPathComponent)) continue;
                CFErrorRef error = NULL;
                if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error)) {
                    NSError *failure = CFBridgingRelease(error);
                    SGLog(@"fonts: %@ not registered: %@", url.lastPathComponent, failure.localizedDescription);
                }
            }
        }
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        [store setObject:kept forKey:SGKeyFontCatalogInstalled];
        [store setObject:families forKey:SGKeyFontCatalogFamilies];
    });
}

BOOL SGFontCatalogHasFamily(NSString *family) {
    if (!family.length) return NO;
    SGFontCatalogRegisterInstalled();
    return [[storedFamilies() allValues] containsObject:family];
}

void SGFontCatalogChoose(SGFontCatalogEntry *entry) {
    if (entry.state != SGFontCatalogInstalled) return;
    // the family the files carry, which may differ from the one the catalog claims
    NSString *family = storedFamilies()[entry.identifier] ?: entry.familyName;
    [NSUserDefaults.standardUserDefaults setObject:family forKey:SGKeyAppFontFamily];
    SGSetInt(SGKeyAppFont, SGAppFontFamily);
}

void SGFontCatalogPreview(SGFontCatalogEntry *entry, void (^done)(UIImage *image, NSError *error)) {
    NSDictionary *preview = entry.preview;
    if (!preview[@"name"]) {
        if (done) done(nil, [NSError errorWithDomain:@"spotifyglass.font" code:2
                                            userInfo:@{NSLocalizedDescriptionKey: @"The catalog has no picture for this font."}]);
        return;
    }
    SGCatalogFile(@"fonts", pathOf(entry.identifier, preview[@"name"]), [preview[@"size"] longLongValue], preview[@"sha256"],
        ^(NSURL *file, NSError *error) { if (done) done(error ? nil : [UIImage imageWithContentsOfFile:file.path], error); });
}
