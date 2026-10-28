#import "SGCatalog.h"
#import <CommonCrypto/CommonDigest.h>

NSNotificationName const SGCatalogDidChangeNotification = @"spotifyglass.catalog.didChange";
NSString *const SGCatalogKindKey = @"kind";
NSString *const SGCatalogErrorKey = @"error";

// One catalog asked for at a time, so a page of rows asking for the same kind shares the reply.
@interface SGCatalogFetchState : NSObject
@property (nonatomic, strong) NSMutableArray<void (^)(id, NSError *)> *waiting;
@property (nonatomic) BOOL fetching;
@property (nonatomic) BOOL refetching;
@end

@implementation SGCatalogFetchState
@end

static NSMutableDictionary<NSString *, SGCatalogFetchState *> *sg_fetches;
static dispatch_queue_t sg_queue;

static dispatch_queue_t queue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_fetches = [NSMutableDictionary dictionary];
        sg_queue = dispatch_queue_create("spotifyglass.catalog", DISPATCH_QUEUE_SERIAL);
    });
    return sg_queue;
}

NSURL *SGCatalogFolder(NSString *kind) {
    static NSMutableDictionary<NSString *, NSURL *> *folders;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ folders = [NSMutableDictionary dictionary]; });
    NSURL *folder = folders[kind];
    if (folder) return folder;
    NSURL *base = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    folder = [base URLByAppendingPathComponent:[@"spoti.pw/Catalog" stringByAppendingPathComponent:kind] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    folders[kind] = folder;
    return folder;
}

static NSURL *catalogURL(NSString *kind) { return [SGCatalogFolder(kind) URLByAppendingPathComponent:@"catalog.json"]; }

// Appending path components to a parsed base URL escapes spaces and other filename characters while
// leaving the catalog's folder structure intact. Building one URL string did not do that for audio
// assets whose checksum is followed by the original human-readable filename.
static NSURL *remoteURL(NSString *kind, NSString *path) {
    NSURL *url = [NSURL URLWithString:SGCatalogBase];
    url = [url URLByAppendingPathComponent:kind];
    for (NSString *component in path.pathComponents)
        if (![component isEqualToString:@"/"]) url = [url URLByAppendingPathComponent:component];
    return url;
}

static NSString *hexSha256Of(NSURL *url) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    if (!file) return nil;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [file readDataUpToLength:1 << 20 error:nil];
            if (!chunk.length) break;
            CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [file closeAndReturnError:nil];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static int64_t sizeAt(NSURL *url) {
    NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil][NSFileSize];
    return size ? size.longLongValue : -1;
}

static BOOL matches(NSURL *url, int64_t size, NSString *sha256) {
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return NO;
    if (size > 0 && sizeAt(url) != size) return NO;
    if (sha256.length && ![hexSha256Of(url) isEqualToString:sha256]) return NO;
    return YES;
}

id SGCatalogCached(NSString *kind) {
    NSData *data = [NSData dataWithContentsOfURL:catalogURL(kind)];
    if (!data) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}

static void post(NSString *kind, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SGCatalogDidChangeNotification
                                                            object:nil
                                                          userInfo:@{SGCatalogKindKey: kind, SGCatalogErrorKey: error ?: [NSNull null]}];
    });
}

// The real fetch, run on the catalog queue: one reply shared by everyone waiting, the cached copy
// handed over at once and the server's copy after it, whichever comes first.
static void beginFetch(NSString *kind, void (^done)(id, NSError *)) {
    SGCatalogFetchState *fetch = sg_fetches[kind];
    if (!fetch) {
        fetch = [SGCatalogFetchState new];
        fetch.waiting = [NSMutableArray array];
        sg_fetches[kind] = fetch;
    }
    id cached = SGCatalogCached(kind);
    if (cached && done) dispatch_async(dispatch_get_main_queue(), ^{ done(cached, nil); });
    if (done) [fetch.waiting addObject:done];
    if (fetch.fetching) {
        // A second ask while one is out only wants to know when it lands.
        return;
    }
    fetch.fetching = YES;
    NSURL *url = remoteURL(kind, @"catalog.json");
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    NSURLSessionDataTask *task = [[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(sg_queue, ^{
            fetch.fetching = NO;
            id json = nil;
            NSError *failure = error;
            if (data.length) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (!json) failure = [NSError errorWithDomain:@"spotifyglass.catalog" code:1
                                                     userInfo:@{NSLocalizedDescriptionKey: @"The catalog could not be read."}];
                else {
                    [data writeToURL:catalogURL(kind) atomically:YES];
                }
            } else if (!cached) {
                failure = failure ?: [NSError errorWithDomain:@"spotifyglass.catalog" code:2
                                                     userInfo:@{NSLocalizedDescriptionKey: @"No connection, and nothing kept from before."}];
            }
            NSArray<void (^)(id, NSError *)> *waiting = fetch.waiting;
            fetch.waiting = [NSMutableArray array];
            post(kind, failure);
            for (void (^done)(id, NSError *) in waiting)
                dispatch_async(dispatch_get_main_queue(), ^{ done(json ?: cached, failure); });
        });
    }];
    [task resume];
}

void SGCatalogFetch(NSString *kind, void (^done)(id json, NSError *error)) {
    done = [done copy];
    dispatch_async(queue(), ^{ beginFetch(kind, done); });
}

static void beginFile(NSString *kind, NSString *path, int64_t size, NSString *sha256, void (^done)(NSURL *, NSError *)) {
    NSURL *file = [SGCatalogFolder(kind) URLByAppendingPathComponent:path];
    if (matches(file, size, sha256)) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(file, nil); });
        return;
    }
    NSURL *folder = [file URLByDeletingLastPathComponent];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *part = [file URLByAppendingPathExtension:@"part"];
    [NSFileManager.defaultManager removeItemAtURL:part error:nil];
    NSURL *url = remoteURL(kind, path);
    NSURLRequest *request = [NSURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:60];
    NSURLSessionDownloadTask *task = [[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]]
       downloadTaskWithRequest:request
             completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSError *failure = error;
        if (!failure && location) {
            if (size > 0 && sizeAt(location) != size)
                failure = [NSError errorWithDomain:@"spotifyglass.catalog" code:3
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ came in the wrong size.", path]}];
            else if (sha256.length && ![hexSha256Of(location) isEqualToString:sha256])
                failure = [NSError errorWithDomain:@"spotifyglass.catalog" code:4
                                          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ did not match its checksum.", path]}];
            else {
                [NSFileManager.defaultManager removeItemAtURL:file error:nil];
                if (![NSFileManager.defaultManager moveItemAtURL:location toURL:file error:&failure]) failure = failure ?: error;
            }
        }
        [NSFileManager.defaultManager removeItemAtURL:part error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ done(failure ? nil : file, failure); });
    }];
    [task resume];
}

void SGCatalogFile(NSString *kind, NSString *path, int64_t size, NSString *sha256, void (^done)(NSURL *file, NSError *error)) {
    done = [done copy];
    dispatch_async(queue(), ^{ beginFile(kind, path, size, sha256, done); });
}

BOOL SGCatalogHasFile(NSString *kind, NSString *path, int64_t size, NSString *sha256) {
    return matches([SGCatalogFolder(kind) URLByAppendingPathComponent:path], size, sha256);
}

void SGCatalogRemoveFile(NSString *kind, NSString *path) {
    if (!kind.length || !path.length) return;
    dispatch_async(queue(), ^{
        NSURL *file = [SGCatalogFolder(kind) URLByAppendingPathComponent:path];
        [NSFileManager.defaultManager removeItemAtURL:file error:nil];
        [NSFileManager.defaultManager removeItemAtURL:[file URLByAppendingPathExtension:@"part"] error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SGCatalogDidChangeNotification
                                                                object:nil
                                                              userInfo:@{SGCatalogKindKey: kind, SGCatalogErrorKey: [NSNull null]}];
        });
    });
}
