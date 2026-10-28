#import "SGSingModel.h"
#import "SGStemWorker.h"
#import "Core/SGLog.h"
#import "Core/SGPrefs.h"
#import "Shared/Catalog/SGCatalog.h"
#import <Network/Network.h>

NSNotificationName const SGSingModelDidChangeNotification = @"spotifyglass.singModelChanged";
NSString *const SGSingModelDidChangeChoiceKey = @"choiceChanged";

#ifndef SGSingModelRoot
#define SGSingModelRoot nil
#endif

static NSString *const kCatalogKind = @"sing";       // the catalog the models are served from
static const NSInteger kModelVersion[2] = {1, 101};  // the full model and the light one, as the catalog names them
static NSString *const kInstalledName[2] = {@"separator.mlmodelc", @"separator-light.mlmodelc"};
// The staging folders of the download this replaced. Nothing writes them any more; they are swept away
// so an old half download does not sit there forever.
static NSString *const kLegacyStaging[2] = {@"Download-vitrine-ane", @"Download-vitrine-light"};

static NSString *const kSessionIdentifier = @"spotifyglass.sing.model";
static NSString *const kDownloadKindKey = @"spotifyglass.sing.modelDownloadKind";
static const int64_t kHeadroom = 64ll << 20;               // free space left over once the model is in
static const NSTimeInterval kProgressInterval = 0.25;      // between two progress notifications
enum { kMaxFiles = 32 };                                   // the most files one model's catalog entry may carry

// The catalog as it stood when this was built, the same values the server sends, so the newer model
// versions are pinned here from the start and the download works before any catalog fetch. A newer
// catalog replaces it in memory as soon as one lands, and the catalog keeps that one on disk for the
// launches in between.
static NSArray<NSDictionary *> *snapshot(void) {
    static NSArray *entries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSDictionary *> *full = @[
            @{ @"path": @"analytics/coremldata.bin", @"size": @243,
               @"sha256": @"f7ee4ec9b5cc1c97171bd5aad93af61e183aa0db1451ef3b775bd4e77f0b7cfd" },
            @{ @"path": @"coremldata.bin", @"size": @507,
               @"sha256": @"2090acaf7a6df72ec83857cb88d101654023a6baad222a25d0173827d3347e28" },
            @{ @"path": @"metadata.json", @"size": @2431,
               @"sha256": @"52a8d5e3f09e33236d495dbed5bbce1c75bac6f2a6b6097637cf214f37c1de53" },
            @{ @"path": @"model.mil", @"size": @669061,
               @"sha256": @"966560ed5125174a98f19b94f5de04450a7112ade0e731f2236c202c0280a623" },
            @{ @"path": @"weights/weight.bin", @"size": @488986336,
               @"sha256": @"970a99fb4b15724bf76d2918ceb177df592c69265d3e2fabaab6e5ba72738e62" },
        ];
        NSArray<NSDictionary *> *light = @[
            @{ @"path": @"analytics/coremldata.bin", @"size": @243,
               @"sha256": @"7e364c0350456bdff703125ab2ac79c779341ffd61d4eb4e988cc8c32486c518" },
            @{ @"path": @"coremldata.bin", @"size": @462,
               @"sha256": @"18a6a90cc596b43f2508f44423957d3bbffc94d45b8184b963f6086cbc055f77" },
            @{ @"path": @"metadata.json", @"size": @2225,
               @"sha256": @"99bba97984cc77c37271c8441f3c89148a83c3088ae657cc7b8e99561879b16d" },
            @{ @"path": @"model.mil", @"size": @104543,
               @"sha256": @"a0d3c8e9cb8d99db81f54c6f5dc22a0ff835510113d7685d89c0ad8b16922d76" },
            @{ @"path": @"weights/weight.bin", @"size": @39302336,
               @"sha256": @"f511e2c558185481ff847e2f2bc34aee38a29af0ef73140eb4dced5c18192d6a" },
        ];
        entries = @[ @{ @"version": @1, @"files": full },
                     @{ @"version": @101, @"files": light } ];
    });
    return entries;
}

// The file tables, one per kind, read out of a catalog's entry. A file the catalog pins no hash for is
// checked on its size alone.
static NSArray<NSString *> *sg_paths[2];
static NSArray<NSNumber *> *sg_sizes[2];
static NSArray<NSString *> *sg_hashes[2];
static id sg_catalog;                      // the JSON the tables were last read from

static BOOL sg_loaded, sg_installed, sg_want;
static SGSingModelKind sg_loadedKind;
static int sg_count[2];
static BOOL sg_done[kMaxFiles], sg_busy[kMaxFiles];
static NSString *sg_failure;
static NSUInteger sg_epoch, sg_tables;     // a completion from before a remove or a new catalog is let go
static NSTimeInterval sg_lastPost;

#pragma mark - the files

// The first mirrored catalog counted metadata.json characters instead of UTF-8 bytes and pinned
// per-download hashes. A kept catalog carrying those stale entries is corrected to the real byte
// sizes here; the snapshot and anything the server sends today already carry them.
static int64_t correctedSize(NSString *path, NSString *sha, int64_t size) {
    if (![path isEqualToString:@"metadata.json"]) return size;
    if ([sha isEqualToString:@"8f0fc20ff2ee448e3e306b0b14f3a670b38b828824dec7279cc5017290ce8d1e"]) return 2431;
    if ([sha isEqualToString:@"3a65ad7f10ad49f45a29f97186149665d8af6733053cb7da1cb09b9ab7f2693f"]) return 2225;
    return size;
}

// Reads a catalog's entries into the tables, keeping whatever a kind's entry does not carry. Called for
// the snapshot, the copy on disk and the server's copy, each filling in what the last left out.
static void setTables(id catalog) {
    if (![catalog isKindOfClass:NSArray.class]) return;
    NSMutableArray<NSString *> *paths[2], *sizes[2], *hashes[2];
    for (int kind = 0; kind < 2; kind++) {
        paths[kind] = [NSMutableArray array];
        sizes[kind] = [NSMutableArray array];
        hashes[kind] = [NSMutableArray array];
    }
    for (NSDictionary *entry in catalog) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSInteger version = [entry[@"version"] isKindOfClass:NSNumber.class] ? [entry[@"version"] integerValue] : 0;
        int kind = version == kModelVersion[SGSingModelFull] ? SGSingModelFull
                 : version == kModelVersion[SGSingModelLight] ? SGSingModelLight : -1;
        if (kind < 0 || ![entry[@"files"] isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *file in entry[@"files"]) {
            if (![file isKindOfClass:NSDictionary.class]) continue;
            NSString *path = [file[@"path"] isKindOfClass:NSString.class] ? file[@"path"] : nil;
            if (!path.length || paths[kind].count >= kMaxFiles) continue;
            int64_t size = [file[@"size"] isKindOfClass:NSNumber.class] ? [file[@"size"] longLongValue] : 0;
            NSString *sha = [file[@"sha256"] isKindOfClass:NSString.class] ? file[@"sha256"] : nil;
            size = correctedSize(path, sha, size);
            [paths[kind] addObject:path];
            [sizes[kind] addObject:@(size)];
            // a short or missing hash stands for "not pinned", and only the size is checked
            [hashes[kind] addObject:sha.length == 64 ? sha : NSNull.null];
        }
    }
    for (int kind = 0; kind < 2; kind++) {
        if (!paths[kind].count) continue;
        sg_paths[kind] = [paths[kind] copy];
        sg_sizes[kind] = [sizes[kind] copy];
        sg_hashes[kind] = [hashes[kind] copy];
        sg_count[kind] = (int)paths[kind].count;
    }
    sg_catalog = catalog;
    sg_tables++;
}

static SGSingModelKind chosenKind(void) {
    return SGInt(SGKeySingModel, SGSingModelFull) == SGSingModelLight ? SGSingModelLight : SGSingModelFull;
}
static int countOfKind(int kind) { return kind == SGSingModelLight || kind == SGSingModelFull ? sg_count[kind] : 0; }
static NSString *pathOf(int i) { return sg_paths[chosenKind()][i]; }
static int64_t sizeOf(int i) { return sg_sizes[chosenKind()][i].longLongValue; }
static NSString *hashOf(int i) {
    NSString *sha = sg_hashes[chosenKind()][i];
    return [sha isKindOfClass:NSString.class] ? sha : nil;
}
// The catalog keeps each model's files under the folder its version names.
static NSString *versionFolder(int kind) { return [NSString stringWithFormat:@"model-%ld", (long)kModelVersion[kind]]; }

static NSURL *singFolder(void) {
    static NSURL *folder;
    if (!folder) {
        NSString *root = SGSingModelRoot;
        NSURL *base = root ? [NSURL fileURLWithPath:root isDirectory:YES]
            : [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        folder = [base URLByAppendingPathComponent:@"spoti.pw/Sing" isDirectory:YES];
    }
    return folder;
}
static NSURL *installedModelOf(int kind) { return [singFolder() URLByAppendingPathComponent:kInstalledName[kind] isDirectory:YES]; }
static NSURL *installedModel(void) { return installedModelOf(chosenKind()); }
static NSURL *storeFolderOf(int kind) { return [SGCatalogFolder(kCatalogKind) URLByAppendingPathComponent:versionFolder(kind)]; }
static NSURL *storeFileOf(int kind, int i) {
    return [storeFolderOf(kind) URLByAppendingPathComponent:sg_paths[kind][i]];
}

static int64_t sizeAt(NSURL *url) {
    NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileSize];
    return size ? size.longLongValue : -1;
}

// Hashing, moving and removing go one after another, off the main thread.
static dispatch_queue_t disk(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("spotifyglass.sing.model", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// The download folders of the pinned repo are no longer written; whatever they hold is junk now.
static void sweepLegacy(void) {
    for (int kind = 0; kind < 2; kind++)
        [NSFileManager.defaultManager removeItemAtURL:[singFolder() URLByAppendingPathComponent:kLegacyStaging[kind]] error:nil];
}

// The folders stay out of the iCloud backup, with what is in them: the model is large and can be had again.
static BOOL makeFolders(NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtURL:storeFolderOf(chosenKind()) withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    [singFolder() setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    [SGCatalogFolder(kCatalogKind) setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    return YES;
}

static void startMissing(void);
static void load(void);
static void installIfComplete(void);
static void post(BOOL progress);

// The server's catalog replaces the tables in memory the first time one lands; the copy it kept on disk
// already stood in for the snapshot until then. A download caught mid-flight goes on from the new
// tables, and whatever the new entry disagrees about starts over.
static void refreshTables(void) {
    static BOOL asked = NO;
    if (asked) return;
    asked = YES;
    SGCatalogFetch(kCatalogKind, ^(id json, NSError *error) {
        if (!json || [json isEqual:sg_catalog]) return;
        BOOL want = sg_want;
        setTables(json);
        sg_loaded = NO;
        load();
        if (want && !sg_installed) {
            sg_want = YES;
            startMissing();
            installIfComplete();
        }
        post(NO);
    });
}

static void load(void) {
    SGSingModelKind kind = chosenKind();
    if (sg_loaded && sg_loadedKind == kind) return;
    sg_loaded = YES;
    sg_loadedKind = kind;
    sg_want = NO;
    sg_installed = NO;
    sg_failure = nil;
    memset(sg_done, 0, sizeof sg_done);
    memset(sg_busy, 0, sizeof sg_busy);
    // The snapshot first, then whatever the catalog last kept on disk over it.
    if (!sg_paths[0] || !sg_paths[1]) {
        setTables(snapshot());
        setTables(SGCatalogCached(kCatalogKind));
    }
    // A model put in place by an older build holds a different file set, so the sizes are not asked for:
    // anything with every file there is the installed model, and stays until Remove or a new download.
    sg_installed = YES;
    for (int i = 0; i < countOfKind(kind); i++)
        sg_installed &= sizeAt([installedModelOf(kind) URLByAppendingPathComponent:sg_paths[kind][i]]) >= 0;
    if (sg_installed) return;
    // What the catalog already holds counts as arrived. It only ever keeps a file it has checked, so the
    // size is match enough here, as it was for the staged folder before.
    for (int i = 0; i < countOfKind(kind); i++)
        sg_done[i] = sizeAt(storeFileOf(kind, i)) == sg_sizes[kind][i].longLongValue;
    refreshTables();
}

static void post(BOOL progress) {
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (progress && now - sg_lastPost < kProgressInterval) return;
    sg_lastPost = now;
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingModelDidChangeNotification object:nil];
}

static void postChoice(void) {
    sg_lastPost = NSProcessInfo.processInfo.systemUptime;
    [NSNotificationCenter.defaultCenter postNotificationName:SGSingModelDidChangeNotification
                                                      object:nil
                                                    userInfo:@{SGSingModelDidChangeChoiceKey: @YES}];
}

static void fail(NSString *failure) {
    SGLog(@"Sing voice model download stopped: %@", failure);
    sg_failure = failure;
    sg_want = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
    post(NO);
}

#pragma mark - the download

static void startFile(int i) {
    sg_busy[i] = YES;
    NSUInteger epoch = sg_epoch, tables = sg_tables;
    SGSingModelKind kind = chosenKind();
    NSString *path = [versionFolder(kind) stringByAppendingPathComponent:pathOf(i)];
    int64_t size = sizeOf(i);
    NSString *sha = hashOf(i);
    // The catalog fetches a file whole and checks it against the entry before it is kept, so there is
    // nothing to pick up inside one file; what is done is done, the rest starts over.
    SGCatalogFile(kCatalogKind, path, size, sha, ^(NSURL *file, NSError *error) {
        if (epoch != sg_epoch || tables != sg_tables || kind != chosenKind()) return;
        sg_busy[i] = NO;
        if (error && sg_want) {
            fail([NSString stringWithFormat:@"The download stopped: %@", error.localizedDescription]);
            return;
        }
        // A cancelled download's file is checked all the same, and what arrived is kept.
        sg_done[i] = !error;
        installIfComplete();
        post(NO);
    });
}

static void startMissing(void) {
    for (int i = 0; i < countOfKind(chosenKind()); i++)
        if (!sg_done[i] && !sg_busy[i]) startFile(i);
}

// Every file in: the model takes the installed one's place in one rename.
static void installIfComplete(void) {
    if (!sg_want) return;
    for (int i = 0; i < countOfKind(chosenKind()); i++) if (!sg_done[i]) return;
    SGSingModelKind kind = chosenKind();
    NSUInteger epoch = sg_epoch, tables = sg_tables;
    NSURL *store = storeFolderOf(kind), *installed = installedModelOf(kind);
    dispatch_async(disk(), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSError *error = nil;
        [files removeItemAtURL:installed error:nil];
        BOOL moved = [files moveItemAtURL:store toURL:installed error:&error];
        if (moved) {
            [installed setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
            sweepLegacy();
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (epoch != sg_epoch || tables != sg_tables || kind != chosenKind() || !sg_want) return;
            if (!moved) { fail([NSString stringWithFormat:@"The voice model could not be put in place: %@", error.localizedDescription]); return; }
            SGLog(@"Sing voice model installed");
            sg_want = NO;
            [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
            [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
            sg_installed = YES;
            memset(sg_done, 0, sizeof sg_done);
            memset(sg_busy, 0, sizeof sg_busy);
            post(NO);
        });
    });
}

#pragma mark - the API

SGSingModelKind SGSingModelChosen(void) { return chosenKind(); }

void SGSingModelChoose(SGSingModelKind kind) {
    if (kind != SGSingModelLight) kind = SGSingModelFull;
    if (kind == chosenKind()) return;
    load();
    if (sg_want) SGSingModelCancel();
    SGSetInt(SGKeySingModel, kind);
    sg_loaded = NO;
    load();
    postChoice();
}

SGSingModelState SGSingModelCurrentState(void) {
    load();
    if (sg_installed) return SGSingModelInstalled;
    if (!sg_want) return SGSingModelMissing;
    int busy = 0;
    for (int i = 0; i < countOfKind(chosenKind()); i++) busy += sg_busy[i];
    return busy ? SGSingModelDownloading : SGSingModelChecking;
}

int64_t SGSingModelSize(void) {
    load();
    int64_t total = 0;
    for (int i = 0; i < countOfKind(chosenKind()); i++) total += sizeOf(i);
    return total;
}

NSString *SGSingModelSizeTextOf(SGSingModelKind kind) {
    load();
    int64_t total = 0;
    for (int i = 0; i < countOfKind(kind); i++) total += sg_sizes[kind][i].longLongValue;
    return [NSString stringWithFormat:@"%lld MB", (total + 500000) / 1000000];
}

int64_t SGSingModelReceived(void) {
    load();
    if (sg_installed) return SGSingModelSize();
    // Progress is told per file: one the catalog already holds counts whole, one still coming counts
    // nothing until it lands.
    int64_t total = 0;
    for (int i = 0; i < countOfKind(chosenKind()); i++)
        total += sg_done[i] ? sizeOf(i) : 0;
    return total;
}

NSString *SGSingModelFailure(void) { return sg_failure; }

NSString *SGSingModelPath(void) {
    load();
    return sg_installed ? installedModel().path : nil;
}

NSString *SGSingModelBytesText(int64_t bytes) {
    if (bytes >= 1ll << 30) return [NSString stringWithFormat:@"%.1f GB", bytes / (double)(1ll << 30)];
    return [NSString stringWithFormat:@"%lld MB", (bytes + (1ll << 19)) >> 20];
}

NSString *SGSingModelSpaceProblem(void) {
    int64_t needed = SGSingModelSize() - SGSingModelReceived() + kHeadroom;
    // The volume is asked through the nearest folder that already exists.
    NSURL *folder = singFolder();
    while (folder.path.length > 1 && ![NSFileManager.defaultManager fileExistsAtPath:folder.path])
        folder = folder.URLByDeletingLastPathComponent;
    NSNumber *free = nil;
    [folder getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    if (!free || free.longLongValue >= needed) return nil;
    return [NSString stringWithFormat:@"Sing's voice model needs %@ of free space, and this iPhone has %@.",
            SGSingModelBytesText(needed), SGSingModelBytesText(free.longLongValue)];
}

void SGSingModelCheckNetwork(void (^done)(SGSingModelNetwork network)) {
    nw_path_monitor_t monitor = nw_path_monitor_create();
    nw_path_monitor_set_queue(monitor, dispatch_get_main_queue());
    __block BOOL answered = NO;
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (answered) return;
        answered = YES;
        SGSingModelNetwork network = nw_path_get_status(path) != nw_path_status_satisfied ? SGSingModelOffline
            : nw_path_is_expensive(path) || nw_path_is_constrained(path) ? SGSingModelMetered : SGSingModelUnmetered;
        nw_path_monitor_cancel(monitor);
        done(network);
    });
    nw_path_monitor_start(monitor);
}

void SGSingModelDownload(BOOL metered) {
    load();
    if (sg_installed || sg_want) return;
    NSError *error = nil;
    if (!makeFolders(&error)) {
        sg_failure = [NSString stringWithFormat:@"The voice model's folder could not be made: %@", error.localizedDescription];
        post(NO);
        return;
    }
    SGLog(@"Sing voice model download starting, %lld of %lld bytes here, %@", SGSingModelReceived(), SGSingModelSize(),
          metered ? @"on any network" : @"off metered networks");
    sg_want = YES;
    sg_failure = nil;
    SGSetInt(SGKeySingModelDownload, metered ? 2 : 1);
    SGSetInt(kDownloadKindKey, chosenKind());
    startMissing();
    installIfComplete();
    post(NO);
}

void SGSingModelCancel(void) {
    load();
    if (!sg_want) return;
    sg_failure = nil;
    sg_want = NO;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
    // The file on the wire cannot be called back, but when it lands it is checked and kept, like the
    // ones before it.
    post(NO);
}

void SGSingModelRemove(void) {
    load();
    SGLog(@"Sing voice model removed");
    sg_epoch++;
    sg_want = NO;
    sg_installed = NO;
    sg_failure = nil;
    memset(sg_done, 0, sizeof sg_done);
    memset(sg_busy, 0, sizeof sg_busy);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
    // The warm model goes now; its files after anything already queued for them.
    SGStemWorkerPurge();
    NSURL *installed = installedModel(), *store = storeFolderOf(chosenKind()), *sing = singFolder();
    dispatch_async(disk(), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        [files removeItemAtURL:installed error:nil];
        [files removeItemAtURL:store error:nil];
        for (int kind = 0; kind < 2; kind++)
            [files removeItemAtURL:[sing URLByAppendingPathComponent:kLegacyStaging[kind]] error:nil];
    });
    post(NO);
}

BOOL SGSingModelHandlesSession(NSString *identifier, void (^completion)(void)) {
    if (![identifier isEqualToString:kSessionIdentifier]) return NO;
    // The download runs on the catalog's own sessions, so no background events arrive any more; the
    // launch is answered at once, as the system asks of whoever takes the completion.
    if (completion) dispatch_async(dispatch_get_main_queue(), completion);
    return YES;
}

void SGSingModelReconnect(void) {
    load();
    NSInteger mode = SGInt(SGKeySingModelDownload, 0);
    if (!mode) return;
    if (SGInt(kDownloadKindKey, SGSingModelFull) != chosenKind()) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
        return;
    }
    if (sg_installed) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kDownloadKindKey];
        return;
    }
    // A download left running picks up per file: what the catalog holds is kept, the rest is asked for
    // again. Nothing survives the process itself, as the background session's tasks once did.
    sg_want = YES;
    startMissing();
    installIfComplete();
    post(NO);
}
