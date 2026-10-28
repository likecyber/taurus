// The lock-screen lyric card: a card is rendered from a css subset, an html-subset template
// and the data dictionary, into a UIImage, entirely natively -- no web view, no script. The
// three builtins ship compiled in; the lockscreen catalog joins them in the picker. Everything
// the caller supplies is the style id, the data, the artwork and the size.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// the chosen style, read at render time; the same constant SGCardCore.m defines
#define SGKeyLockCardStyle "spotifyglass.lockCard.style"

// posted when SGLockCardSetStyle stores a new id; the picker and the preview re-read
extern NSNotificationName const SGLockCardStyleDidChangeNotification;

// id -> {id, name, author:"", fonts:[], template, css} for classic, vinyl and messages
NSDictionary *SGLockCardBuiltinStyles(void);

// the catalog's styles as the same shape, ids "catalog:<uuid>"; empty until the fetch lands
NSArray<NSDictionary *> *SGLockCardCatalogStyles(void);

// asks the catalog server for the lockscreen kind again; SGLockCardCatalogStyles answers the
// kept copy at once and the fresh one after
void SGLockCardRefreshCatalog(void);

// stores the choice and posts SGLockCardStyleDidChangeNotification
void SGLockCardSetStyle(NSString *styleID);

// the stored choice, "builtin:classic" when nothing is stored or the entry left
NSString *SGLockCardStyleID(void);

// registers the chosen style's fonts through the FontCatalog, once; call before rendering.
// A family still on its way falls back to the next one in the style's list until it lands.
void SGLockCardRegisterFonts(void);

// the whole pipeline: template + data -> UIImage at `scale`, nil plus a reason on failure.
// The data dictionary carries the strings (kind, index, count, lang, dir, title, artist,
// album, prev, prevTime, time, translation, next, nextTime, clock) and words = [{word, i}];
// safeTop and safeBottom (NSNumber, points) seed --safe-top/--safe-bottom, 59 and 34 by default.
UIImage * _Nullable SGLockCardRender(NSString *styleID, NSDictionary *data, UIImage * _Nullable cover,
                                     CGFloat width, CGFloat height, CGFloat scale, NSString * _Nullable * _Nullable errorOut);

// the data a preview renders with, previews and tests alike
NSDictionary *SGLockCardSampleData(void);

// the styles page: a preview header rendering the chosen style with the sample data, then a
// row per builtin and catalog style with a tick on the chosen one, then the refresh row.
// Not wired anywhere; the integrator adds SGPageRow to its page.
UIViewController *SGLockCardStylesPage(void);

NS_ASSUME_NONNULL_END
