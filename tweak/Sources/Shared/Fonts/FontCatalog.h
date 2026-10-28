// The remote catalog of fonts beside the file of the user's own (FontImport.m): the fonts catalog
// (Shared/Catalog) lists families to download, every file of an entry checked against its size and
// SHA-256 on the way in, the family read from them and registered with Core Text for this process the
// way an import is, and kept for the next launches. A downloaded font is chosen as SGAppFontFamily
// with its family in SGKeyAppFontFamily, exactly the choice a family iOS carries gets, so everything
// Fonts.x does to a family it does to this one too.
#import <UIKit/UIKit.h>

// The ids whose files are on disk, and each one's family as it was read from the files.
#define SGKeyFontCatalogInstalled @"spotifyglass.font.catalog.installed"
#define SGKeyFontCatalogFamilies @"spotifyglass.font.catalog.families"

typedef NS_ENUM(NSInteger, SGFontCatalogState) {
    SGFontCatalogAbsent,       // nothing of it on this iPhone
    SGFontCatalogDownloading,  // its files are on their way, progress tells how far
    SGFontCatalogInstalled,    // registered and kept, here again at the next launches
};

@interface SGFontCatalogEntry : NSObject
@property (nonatomic, readonly) NSString *identifier;   // the catalog's id, and the name of its folder
@property (nonatomic, readonly) NSString *name;         // what a page shows
@property (nonatomic, readonly) NSString *familyName;   // the family the catalog says the files carry
@property (nonatomic, readonly) NSString *designer;
@property (nonatomic, readonly) NSString *category;
@property (nonatomic, readonly) NSString *styles;
@property (nonatomic, readonly) NSString *license;
@property (nonatomic, readonly) NSArray<NSDictionary *> *files;   // each with name, size, sha256; OFL.txt among them
@property (nonatomic, readonly) NSDictionary *preview;            // name, size, sha256 of the picture, or nil
@property (nonatomic, readonly) int64_t downloadSize;             // every file together, bytes
- (SGFontCatalogState)state;
- (double)progress;        // 0 to 1 by the bytes in, 1 once installed
- (NSError *)error;        // why the last download failed, until it is tried again
- (NSURL *)licenseURL;     // the OFL text once its file is on disk, or nil
- (void)download;          // every file, then the registration; said through the notification
- (void)remove;            // the files gone and the family unregistered; Default comes back if it was chosen
@end

extern NSNotificationName const SGFontCatalogDidChangeNotification;   // the list changed, or one entry moved
extern NSString *const SGFontCatalogEntryKey;   // userInfo: the entry whose state moved, nil for the list itself
extern NSString *const SGFontCatalogErrorKey;   // userInfo: why a fetch or a download failed, NSNull when not

// The entries, from the cached catalog at once with the fresh one asked for in the background either
// way, so the first call fetches and the rest wait for the notification. The same objects come back
// each time, so a page can hold on to them.
NSArray<SGFontCatalogEntry *> *SGFontCatalogEntries(void);
// Asks the server for the catalog again, cached or not.
void SGFontCatalogRefresh(void);
// Registers every downloaded font with Core Text for this process, once; Fonts.x does it at launch and
// a page drawing previews does it too. A face already registered is refused and stays registered all the same.
void SGFontCatalogRegisterInstalled(void);
// Whether a downloaded font answers to this family name, its files still on disk.
BOOL SGFontCatalogHasFamily(NSString *family);
// Chooses the font the way the Font page chooses a family iOS carries; nothing happens before it is downloaded.
void SGFontCatalogChoose(SGFontCatalogEntry *entry);
// The entry's picture, from disk or fetched; `done` runs on the main queue, an error without a picture in the catalog.
void SGFontCatalogPreview(SGFontCatalogEntry *entry, void (^done)(UIImage *image, NSError *error));
