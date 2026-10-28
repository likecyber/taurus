// The asset catalogs: the files a feature downloads on request, named by the folder they live in on the
// server. Each catalog is one folder -- fonts, audio, shaders, lyrics-shaders, lockscreen, sing -- whose
// catalog.json lists the entries and every file's size and SHA-256, so a download is checked before it is
// kept and anything already on disk in the right shape is served without a round trip.
#import <Foundation/Foundation.h>

#ifndef SGCatalogBase
#define SGCatalogBase @"https://gitlab.com/likecyber/tauruschroma-assets/-/raw/main"
#endif

// Posted when a catalog arrives from the server, fresh or unchanged; userInfo carries SGCatalogKindKey.
extern NSNotificationName const SGCatalogDidChangeNotification;
extern NSString *const SGCatalogKindKey;
extern NSString *const SGCatalogErrorKey;

// The catalog's JSON as it is on the server (an array or a dictionary), from disk when it is there and
// the network adds nothing, asked for again in the background either way. `done` runs on the main queue.
void SGCatalogFetch(NSString *kind, void (^done)(id json, NSError *error));

// The last catalog of a kind this iPhone kept, nil without one. Never touches the network.
id SGCatalogCached(NSString *kind);

// One file of a kind, `path` relative to the kind's folder: served from disk when its size and SHA-256
// match, downloaded, checked and renamed into place when they do not, and `done` runs on the main queue
// with the file's URL or why it failed. `sha256` may be nil to check the size alone.
void SGCatalogFile(NSString *kind, NSString *path, int64_t size, NSString *sha256, void (^done)(NSURL *file, NSError *error));

// Whether a matching copy of the file is already on disk, without downloading anything.
BOOL SGCatalogHasFile(NSString *kind, NSString *path, int64_t size, NSString *sha256);
// Removes one cached asset. Catalog metadata and other kinds are untouched.
void SGCatalogRemoveFile(NSString *kind, NSString *path);

// The folder a kind keeps its files in, created on first ask, inside Application Support/spoti.pw/Catalog.
NSURL *SGCatalogFolder(NSString *kind);
