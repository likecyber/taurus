// The community presets: the "audio" catalog's entries (Shared/Catalog/SGCatalog.h), each a name, a set of
// settings in the upstream preset keys AudioEffectsPresets.h answers, and the files a file effect needs.
// The list answers offline from the copy the catalog keeps on disk; a pick's files land in the file
// libraries the engine reads, under names of their own, and the settings then go through the same door the
// built-in presets do. API only; the page that shows it is someone else's.
#import <Foundation/Foundation.h>

// Posted on the main thread whenever a fetch has brought a list, fresh or the kept copy. The catalog's own
// SGCatalogDidChangeNotification (kind "audio") fires alongside it, carrying the error when there was one.
extern NSNotificationName const SGDSPCommunityChangedNotification;

// One entry of the catalog. The identifier is the entry's id, and what its files are asked for by.
@interface SGDSPCommunityPreset : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *summary;   // nil without one
@property (nonatomic, copy, readonly) NSString *author;    // nil without one
@property (nonatomic, readonly) NSInteger likeCount;
// A file of the entry the catalog folder has not got a checked copy of on disk yet.
@property (nonatomic, readonly) BOOL needsDownload;
@end

// The catalog as it was last fetched, from the copy kept on disk when nothing has been fetched this run,
// empty when there is none (first run, offline). Main thread.
NSArray<SGDSPCommunityPreset *> *SGDSPCommunityPresets(void);

// Asks for the catalog again: the kept list answers at once where there is one, and the server's comes
// when it comes, offline or not. The changed notification is posted for whichever arrives.
void SGDSPCommunityRefresh(void);

// An entry applied: its files fetched (a copy already on disk and right is kept), landed in the file
// libraries the engine reads, then its settings through SGDSPLoadPresetSettings, the master switch coming
// on with them. An entry whose files will not come is not applied at all. `done` once on the main queue,
// nil or why not.
void SGDSPCommunityApply(SGDSPCommunityPreset *preset, void (^done)(NSString *error));
