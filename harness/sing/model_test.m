// The production voice model download (Shared/Sing/SGSingModel.m, over Shared/Catalog/SGCatalog.m)
// against a local server model_test.py runs: the catalog answered, every file checked against its size
// and SHA-256, a corrupted file rejected, a cancel keeping the files already in, the install, and
// removal. The catalog fetches a file whole, so there is no picking a file up inside itself; what a
// cancel keeps is the files that landed whole before it.
//   model-test all        a corrupted file rejected, a cancel keeping what came in, the install, removal
//   model-test leave      starts a throttled download and exits with it running
//   model-test reconnect  picks that download up the way a launch does, and waits for the install
#import <Foundation/Foundation.h>
#import "Shared/Sing/SGSingModel.h"
#import "Shared/Catalog/SGCatalog.h"
#import <assert.h>

static unsigned purges;
void SGStemWorkerPurge(void) { purges++; }

static NSString *serverBase(void) { return SGCatalogBase; }
static NSURL *folder(void) { return [NSURL fileURLWithPath:[SGSingModelRoot stringByAppendingPathComponent:@"spoti.pw/Sing"]]; }
static NSURL *store(void) { return [NSURL fileURLWithPath:[SGSingModelRoot stringByAppendingPathComponent:@"spoti.pw/Catalog/sing"]]; }

// The server's control endpoint, asked outside the main queue so the main run loop can wait for it.
static NSDictionary *control(NSString *query) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@control?%@", serverBase(), query]];
    __block NSDictionary *answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (data) answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    assert(answer);
    return answer;
}

static BOOL waitFor(NSTimeInterval seconds, BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow < 0) return NO;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return YES;
}

static BOOL exists(NSURL *url) { return [NSFileManager.defaultManager fileExistsAtPath:url.path]; }
static NSURL *under(NSString *path) { return [folder() URLByAppendingPathComponent:path]; }

static void checkInstalled(void) {
    assert(SGSingModelCurrentState() == SGSingModelInstalled);
    NSString *model = SGSingModelPath();
    assert([model isEqualToString:under(@"separator.mlmodelc").path]);
    for (NSString *name in @[@"weights/weight.bin", @"model.mil", @"metadata.json", @"coremldata.bin", @"analytics/coremldata.bin"])
        assert(exists([NSURL fileURLWithPath:[model stringByAppendingPathComponent:name]]));
    assert(!exists(store()));   // the whole store folder became the installed one
    NSNumber *excluded = nil;
    [folder() getResourceValue:&excluded forKey:NSURLIsExcludedFromBackupKey error:nil];
    assert(excluded.boolValue);
    assert(SGSingModelReceived() == SGSingModelSize() && !SGSingModelFailure());
}

static void removeAll(void) {
    unsigned before = purges;
    SGSingModelRemove();
    assert(SGSingModelCurrentState() == SGSingModelMissing && !SGSingModelPath() && purges == before + 1);
    assert(waitFor(10, ^{ return (BOOL)!exists(under(@"separator.mlmodelc")); }));
    assert(!exists([store() URLByAppendingPathComponent:@"model-1"]));
}

static void corrupted(void) {
    control(@"corrupt=1&throttle=0&reset=1");
    SGSingModelDownload(NO);
    assert(SGSingModelCurrentState() == SGSingModelDownloading);
    assert(waitFor(120, ^{ return (BOOL)(SGSingModelFailure() != nil); }));
    assert(SGSingModelCurrentState() == SGSingModelMissing && !SGSingModelPath());
    assert([SGSingModelFailure() containsString:@"did not match"]);
    // The corrupted file was refused, and nothing was put in place.
    assert(!exists(under(@"separator.mlmodelc")));
    printf("corrupted model.mil rejected: %s\n", SGSingModelFailure().UTF8String);
    SGSingModelRemove();
    assert(waitFor(10, ^{ return (BOOL)!exists(store()); }));
}

// The small files land whole while the weights crawl, so a cancel keeps them; the next download asks
// for the weights alone.
static void cancelKeepsFiles(void) {
    control(@"corrupt=0&throttle=40000000&reset=1");
    SGSingModelDownload(NO);
    int64_t full = SGSingModelSize();
    assert(waitFor(120, ^{ return (BOOL)(SGSingModelReceived() > 0 && SGSingModelReceived() < full); }));
    SGSingModelCancel();
    assert(SGSingModelCurrentState() == SGSingModelMissing && !SGSingModelFailure());
    int64_t kept = SGSingModelReceived();
    assert(kept > 0 && kept < full);
    assert(waitFor(10, ^{ return (BOOL)(SGSingModelReceived() == kept); }));   // the file on the wire settles, and is kept or refused whole
    printf("cancelled with %lld of %lld bytes in\n", kept, full);

    control(@"throttle=0&reset=1");
    SGSingModelDownload(NO);
    assert(SGSingModelCurrentState() == SGSingModelDownloading);
    assert(waitFor(300, ^{ return (BOOL)(SGSingModelCurrentState() == SGSingModelInstalled || SGSingModelFailure()); }));
    if (SGSingModelFailure()) { fprintf(stderr, "failed: %s\n", SGSingModelFailure().UTF8String); abort(); }
    checkInstalled();
    NSDictionary *stats = control(@"stats=1");
    NSDictionary *requests = stats[@"requests"];
    // Every file but the weights was already in, so only the weights were asked for again.
    assert(requests.count == 1 && requests[[NSString stringWithFormat:@"sing/model-1/%@", @"weights/weight.bin"]]);
    printf("the files already in were not asked for again; installed\n");
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *mode = argc > 1 ? @(argv[1]) : @"all";
    if ([mode isEqualToString:@"all"]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModelDownload];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeySingModel];
        assert(SGSingModelCurrentState() == SGSingModelMissing && SGSingModelSize() > (100ll << 20));
        assert([SGSingModelSizeTextOf(SGSingModelFull) containsString:@"MB"]);
        SGSingModelChoose(SGSingModelLight);
        assert(SGSingModelChosen() == SGSingModelLight && SGSingModelCurrentState() == SGSingModelMissing);
        int64_t light = SGSingModelSize();
        assert(light > 0 && light < (16ll << 20));
        assert([SGSingModelSizeTextOf(SGSingModelLight) containsString:@"MB"]);
        SGSingModelChoose(SGSingModelFull);
        assert(SGSingModelChosen() == SGSingModelFull && SGSingModelSize() > (100ll << 20));
        corrupted();
        cancelKeepsFiles();
        removeAll();
        printf("model download: corrupted file rejected, cancel kept its files, install, removal passed\n");
    } else if ([mode isEqualToString:@"leave"]) {
        control(@"corrupt=0&throttle=40000000&reset=1");
        SGSingModelDownload(NO);
        assert(waitFor(120, ^{ return (BOOL)(SGSingModelReceived() > 0); }));
        assert([NSUserDefaults.standardUserDefaults integerForKey:SGKeySingModelDownload] == 1);
        printf("left the download running at %lld bytes\n", SGSingModelReceived());
        exit(0);   // no cancel: whatever landed whole stays for the next process, as a suspended app's would
    } else if ([mode isEqualToString:@"reconnect"]) {
        control(@"throttle=0");
        assert(SGSingModelCurrentState() == SGSingModelMissing);
        SGSingModelReconnect();
        assert(SGSingModelCurrentState() != SGSingModelMissing);
        assert(waitFor(300, ^{ return (BOOL)(SGSingModelCurrentState() == SGSingModelInstalled || SGSingModelFailure()); }));
        if (SGSingModelFailure()) { fprintf(stderr, "failed: %s\n", SGSingModelFailure().UTF8String); abort(); }
        checkInstalled();
        assert(![NSUserDefaults.standardUserDefaults objectForKey:SGKeySingModelDownload]);
        NSDictionary *stats = control(@"stats=1");
        printf("reconnected at launch and installed; %lu file request(s) came after the ones kept\n",
               (unsigned long)[stats[@"requests"] count]);
        removeAll();
    }
} return 0; }
