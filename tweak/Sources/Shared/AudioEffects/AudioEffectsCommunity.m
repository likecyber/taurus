#import "Core/SGCore.h"
#import "Shared/Catalog/SGCatalog.h"
#import "AudioEffects.h"
#import "AudioEffectsApply.h"
#import "AudioEffectsPresets.h"
#import "AudioEffectsCommunity.h"

NSNotificationName const SGDSPCommunityChangedNotification = @"spotifyglass.dsp.community.changed";

// The parts a page never sees: what the entry carries and whether its files' state was asked for yet.
// The readonly ones of the header are redeclared readwrite so the parser can fill them in.
@interface SGDSPCommunityPreset ()
@property (nonatomic, copy, readwrite) NSString *identifier, *name, *summary, *author;
@property (nonatomic, readwrite) NSInteger likeCount;
@property (nonatomic, copy) NSArray<NSDictionary *> *files;
@property (nonatomic, copy) NSDictionary<NSString *, id> *settings;
@property (nonatomic) NSInteger downloadState;   // 0 asks again, 1 is on disk, 2 wants files
@end

static NSString *const kKind = @"audio";

static NSString *stringOf(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

#pragma mark - an entry

// The path one of an entry's files keeps in the catalog's folder, by its checksum where it has one.
static NSArray<NSString *> *catalogPaths(NSString *identifier, NSDictionary *file) {
    NSArray *kept = [file[@"_catalogPaths"] isKindOfClass:NSArray.class] ? file[@"_catalogPaths"] : nil;
    if (kept.count) return kept;
    NSString *sha = stringOf(file[@"sha256"]), *name = stringOf(file[@"name"]).lastPathComponent;
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (sha.length && name.length) [paths addObject:[NSString stringWithFormat:@"%@/%@_%@", identifier, sha, name]];
    if (sha.length) [paths addObject:[NSString stringWithFormat:@"%@/%@", identifier, sha]];
    else if (name.length) [paths addObject:[NSString stringWithFormat:@"%@/%@", identifier, name]];
    return paths;
}

static BOOL fileOnDisk(NSDictionary *file, NSString *identifier) {
    int64_t size = [file[@"size"] isKindOfClass:NSNumber.class] ? [file[@"size"] longLongValue] : 0;
    for (NSString *path in catalogPaths(identifier, file))
        if (SGCatalogHasFile(kKind, path, size, stringOf(file[@"sha256"]))) return YES;
    return catalogPaths(identifier, file).count == 0;
}

// A catalog file is normally under its preset id. Identical checksum-addressed files can be shared
// by more than one preset, though, and older mirrors kept either `<sha>` or `<sha>_<name>`. Try every
// catalog-proven location and keep the first copy that passes the same size and SHA-256 check.
static void fetchFile(NSArray<NSString *> *paths, int64_t size, NSString *sha,
                      void (^done)(NSURL *file, NSError *error)) {
    __block void (^tryPath)(NSUInteger);
    tryPath = ^(NSUInteger index) {
        if (index >= paths.count) {
            NSError *error = [NSError errorWithDomain:@"spotifyglass.audio.catalog" code:1
                                             userInfo:@{NSLocalizedDescriptionKey: @"No checked copy exists in the audio catalog."}];
            done(nil, error);
            tryPath = nil;
            return;
        }
        SGCatalogFile(kKind, paths[index], size, sha, ^(NSURL *file, NSError *error) {
            if (file) {
                done(file, nil);
                tryPath = nil;
            } else {
                tryPath(index + 1);
            }
        });
    };
    tryPath(0);
}

// The library a file belongs in, by its extension first and its kind on the server then.
static SGDSPFileKind kindOfFile(NSDictionary *file) {
    NSString *extension = stringOf(file[@"name"]).pathExtension.lowercaseString;
    NSString *kind = stringOf(file[@"kind"]).lowercaseString;
    if ([extension isEqualToString:@"vdc"]) return SGDSPFileDDC;
    if ([extension isEqualToString:@"eel"]) return SGDSPFileLiveprog;
    if ([extension isEqualToString:@"wav"] || [extension isEqualToString:@"flac"] || [extension isEqualToString:@"irs"])
        return SGDSPFileImpulseResponse;
    if ([kind isEqualToString:@"ddc"]) return SGDSPFileDDC;
    if ([kind isEqualToString:@"liveprog"]) return SGDSPFileLiveprog;
    return SGDSPFileImpulseResponse;   // "ir", and whatever else is a WAV by another name
}

// The key that chooses a library's file for an effect.
static NSString *fileKeyOfKind(SGDSPFileKind kind) {
    switch (kind) {
    case SGDSPFileImpulseResponse: return SGKeyDSPConvolverFile;
    case SGDSPFileDDC: return SGKeyDSPDDCFile;
    case SGDSPFileLiveprog: return SGKeyDSPLiveprogFile;
    }
    return nil;
}

// The settings key naming a file by its checksum, and the key that chooses it.
static NSString *fileKeyOfSetting(NSString *setting) {
    if ([setting isEqualToString:@"convolver.file"]) return SGKeyDSPConvolverFile;
    if ([setting isEqualToString:@"ddc.file"]) return SGKeyDSPDDCFile;
    if ([setting isEqualToString:@"liveprog.file"]) return SGKeyDSPLiveprogFile;
    return nil;
}

// The name a file lands under in its library: the entry's own plus the id's first eight characters, so
// two entries of one name, and the user's own imported files, are never written over.
static NSString *libraryName(SGDSPCommunityPreset *preset, NSDictionary *file) {
    SGDSPFileKind kind = kindOfFile(file);
    NSString *extension = stringOf(file[@"name"]).pathExtension.lowercaseString;
    if (!extension.length) extension = kind == SGDSPFileDDC ? @"vdc" : kind == SGDSPFileLiveprog ? @"eel" : @"wav";
    NSString *base = preset.name.lastPathComponent.length ? preset.name.lastPathComponent : @"Preset";
    NSString *shortID = [preset.identifier substringWithRange:NSMakeRange(0, MIN(8, preset.identifier.length))];
    return [NSString stringWithFormat:@"%@ (%@).%@", base, shortID, extension];
}

// The fetched copy into the library the engine reads the file effects from, its name back or nil.
static NSString *landInLibrary(SGDSPFileKind kind, NSString *name, NSURL *fetched) {
    NSData *data = [NSData dataWithContentsOfURL:fetched];
    if (!data) return nil;
    NSString *path = [SGDSPLibraryDirectory(kind) stringByAppendingPathComponent:name];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return nil;
    SGLog(@"dsp: %@ added to the community presets' library (%lu bytes)", name, (unsigned long)data.length);
    // A file an effect is playing from is read again, the way an import is.
    NSString *key = fileKeyOfKind(kind);
    if (key && [SGDSPString(key) isEqualToString:name]) SGDSPApply(SGDSPEffectOf(key));
    return name;
}

@implementation SGDSPCommunityPreset

// Asked for until it has been answered once, so a list of rows does not hash every file of the catalog
// each time it draws; a fetch or an apply starts the question over.
- (BOOL)needsDownload {
    if (!_downloadState) {
        BOOL wanted = NO;
        for (NSDictionary *file in _files) wanted = wanted || !fileOnDisk(file, _identifier);
        _downloadState = wanted ? 2 : 1;
    }
    return _downloadState == 2;
}

@end

#pragma mark - the list

static NSArray<SGDSPCommunityPreset *> *sg_presets;

// The entries the catalog answers with, whatever its format: the settings are read key by key, so the two
// the server speaks parse the same. An entry without an id, a name or settings is not one.
static NSArray<SGDSPCommunityPreset *> *parse(id json) {
    if (![json isKindOfClass:NSArray.class]) return nil;
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *locations = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in (NSArray *)json) {
        NSString *identifier = stringOf(entry[@"id"]);
        if (!identifier.length) continue;
        for (NSDictionary *file in [entry[@"files"] isKindOfClass:NSArray.class] ? entry[@"files"] : @[]) {
            NSString *sha = stringOf(file[@"sha256"]);
            if (!sha.length) continue;
            NSMutableArray *paths = locations[sha] ?: (locations[sha] = [NSMutableArray array]);
            for (NSString *path in catalogPaths(identifier, file)) if (![paths containsObject:path]) [paths addObject:path];
        }
    }
    NSMutableArray<SGDSPCommunityPreset *> *presets = [NSMutableArray array];
    for (NSDictionary *entry in (NSArray *)json) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary<NSString *, id> *settings =
            [entry[@"settings"] isKindOfClass:NSDictionary.class] ? entry[@"settings"] : nil;
        NSString *identifier = stringOf(entry[@"id"]), *name = stringOf(entry[@"name"]);
        if (!identifier.length || !name.length || !settings.count) continue;
        SGDSPCommunityPreset *preset = [SGDSPCommunityPreset new];
        preset.identifier = identifier;
        preset.name = name;
        preset.summary = stringOf(entry[@"summary"]) ?: stringOf(entry[@"description"]);
        preset.author = stringOf(entry[@"author"]);
        preset.likeCount = [entry[@"likeCount"] isKindOfClass:NSNumber.class] ? [entry[@"likeCount"] integerValue] : 0;
        NSMutableArray<NSDictionary *> *files = [NSMutableArray array];
        for (NSDictionary *file in [entry[@"files"] isKindOfClass:NSArray.class] ? entry[@"files"] : @[]) {
            if (![file isKindOfClass:NSDictionary.class] || (!stringOf(file[@"sha256"]).length && !stringOf(file[@"name"]).length)) continue;
            NSMutableDictionary *copy = [file mutableCopy];
            NSArray *paths = locations[stringOf(file[@"sha256"])] ?: catalogPaths(identifier, file);
            copy[@"_catalogPaths"] = paths;
            [files addObject:copy];
        }
        preset.files = files;
        preset.settings = settings;
        [presets addObject:preset];
    }
    return presets;
}

NSArray<SGDSPCommunityPreset *> *SGDSPCommunityPresets(void) {
    if (!sg_presets) sg_presets = parse(SGCatalogCached(kKind)) ?: @[];
    return sg_presets;
}

// The catalog hands over the kept copy at once and the server's after it, whichever answers, so this runs
// twice when there is one of each and the page reloads twice with it.
void SGDSPCommunityRefresh(void) {
    SGCatalogFetch(kKind, ^(id json, NSError *error) {
        NSArray<SGDSPCommunityPreset *> *presets = parse(json);
        if (!presets) {
            // Offline and nothing kept: the list stays as it was, the catalog's notification carries the error.
            SGLog(@"dsp: the community presets have nothing new (%@)", error.localizedDescription ?: @"no answer");
            return;
        }
        sg_presets = presets;
        [[NSNotificationCenter defaultCenter] postNotificationName:SGDSPCommunityChangedNotification object:nil];
    });
}

#pragma mark - applying one

void SGDSPCommunityApply(SGDSPCommunityPreset *preset, void (^done)(NSString *error)) {
    void (^finish)(NSString *) = done ? [done copy] : nil;
    NSDictionary<NSString *, id> *settings = preset.settings;
    if (!settings.count) {
        if (finish) finish(@"The preset has no settings");
        return;
    }
    __block NSString *failure = nil;
    // What came in, by its checksum and by its name, for the settings' file keys to be read against.
    __block NSMutableArray<NSDictionary<NSString *, NSString *> *> *landed = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    for (NSDictionary *file in preset.files) {
        NSArray<NSString *> *paths = catalogPaths(preset.identifier, file);
        if (!paths.count) continue;
        int64_t size = [file[@"size"] isKindOfClass:NSNumber.class] ? [file[@"size"] longLongValue] : 0;
        dispatch_group_enter(group);
        fetchFile(paths, size, stringOf(file[@"sha256"]), ^(NSURL *fetched, NSError *error) {
            NSString *name = libraryName(preset, file);
            if (error) failure = failure ?: [NSString stringWithFormat:@"%@ would not come (%@)", name, error.localizedDescription];
            else if (!landInLibrary(kindOfFile(file), name, fetched))
                failure = failure ?: [NSString stringWithFormat:@"%@ could not be put in the library", name];
            else
                [landed addObject:@{@"sha": stringOf(file[@"sha256"]) ?: @"", @"name": stringOf(file[@"name"]) ?: @"",
                                    @"library": name}];
            dispatch_group_leave(group);
        });
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (failure) {
            SGLog(@"dsp: the community preset %@ was not applied (%@)", preset.name, failure);
            if (finish) finish(failure);
            return;
        }
        SGDSPLoadPresetSettings(settings);
        // The settings' file keys carry checksums; what the effects play from now are the libraries' names.
        for (NSString *setting in settings) {
            NSString *key = fileKeyOfSetting(setting);
            NSString *wanted = stringOf(settings[setting]);
            if (!key || !wanted.length) continue;
            for (NSDictionary *one in landed) {
                if ([one[@"sha"] isEqualToString:wanted] || [one[@"name"] isEqualToString:wanted]) {
                    SGDSPSetString(key, one[@"library"]);
                    break;
                }
            }
        }
        preset.downloadState = 0;   // what it wanted is on disk now
        SGLog(@"dsp: the community preset %@ applied", preset.name);
        if (finish) finish(nil);
    });
}
