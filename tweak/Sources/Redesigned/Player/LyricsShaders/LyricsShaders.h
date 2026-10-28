// The GPU lyrics typesetter: Core Text on one side, the linemap Metal pass on the other. It
// typesets the karaoke lines (Shared/Lyrics) the way the player's lyrics page shows them and
// draws them into the textures the lyrics shaders read: the linemap's atlas of line rasters
// (SGRLyricsEngine.m) and, for the styles and the `text` input, the strip textures whose rows
// hold one line each. The style pass itself stays with the integrator; the engine only feeds.
//
// Runs under the redesign only, and only while a lyrics-using style is visible
// (SGRLyricsShaderSetVisible); SGRLyricsShaderUpdate is the per-frame pump.
//
// Threading: main thread only. The Metal pieces come alive on SGRLyricsShaderUseDevice, with
// the caller's device, so the linemap shares its command buffers.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

// Posted on the main queue when the catalog's lyrics-shaders arrived, fresh or unchanged.
extern NSNotificationName const SGRLyricsShaderDidChangeNotification;

// Every selectable lyrics style, compiled-in first: Poster and Cut, then the catalog's. Each
// dict carries: identifier ("builtin:poster", "builtin:cut", "cat:<uuid>@<versionId>"), name,
// detail, author, fps, scale, uses ("lyrics" plus "clip" and "tilt" as the entry names them),
// params (the manifest's, each with its slot for the frame's param slots), builtin (BOOL),
// background (BOOL, the style draws a background layer of its own and wants to sit behind
// lyrics), family (the catalog font family a catalog entry asks for, absent for the builtins).
NSArray<NSDictionary *> *SGRLyricsShaderInfos(void);

// The compiled-in Metal sources (SGRLyricsBuiltins.m): 0 the linemap pass, 1 Poster, 2 Cut.
// A catalog entry's source comes through SGRLyricsShaderLoadSource instead.
NSString *SGRLyricsBuiltinSource(NSInteger index);

// A style's Metal source: the compiled-in ones at once, a catalog entry fetched on the first
// ask and kept. `done` runs on the main queue, with nil when it could not be had.
void SGRLyricsShaderLoadSource(NSString *identifier, void (^done)(NSString * _Nullable msl, NSDictionary * _Nullable manifest));

// The style the engine typesets and lays out for: an identifier from the infos. Poster until
// set. The font, case and tracking follow the style, so switch before the player shows it.
void SGRLyricsShaderSetStyle(NSString *identifier);
NSString *SGRLyricsShaderStyle(void);

// YES while a lyrics-using style shows: the engine then reads the clock, retypesets on line
// changes and refills its textures. NO idles everything, keeping the last frame drawn.
void SGRLyricsShaderSetVisible(BOOL visible);

// The per-frame pump: reads the player's clock, retypesets when the line window moved, refills
// the strip and text feeds, and refreshes the frame the linemap packs. Cheap on steady frames.
void SGRLyricsShaderUpdate(void);

// Gives the engine the device to build its linemap pipeline on. Once, before the first draw.
void SGRLyricsShaderUseDevice(id<MTLDevice> device, id<MTLCommandQueue> queue);

// Encodes the linemap pass onto `buffer`, drawing every visible line into `intoTexture`
// (`size` in pixels, the view's at the shader's scale) laid out in the style's column.
// `params` may carry safeArea (NSValue-edged UIEdgeInsets) and column (NSValue CGRect) in
// points; nil takes the defaults. Call after SGRLyricsShaderUpdate, before the style pass.
void SGRLyricsShaderDraw(id<MTLCommandBuffer> buffer, id<MTLTexture> intoTexture, CGSize size,
                         NSDictionary * _Nullable params);

// A catalog lyrics style has the line/background ABI, not the player shader ABI. Compile its
// renamed source here, then draw its optional background and its typeset column into `target`.
BOOL SGRLyricsShaderBuildCatalogStyle(NSString *identifier, NSString *source, MTLPixelFormat format,
                                      NSString * _Nullable * _Nullable failure);
void SGRLyricsShaderDrawCatalogStyle(id<MTLCommandBuffer> buffer, id<MTLTexture> target, CGSize size,
                                     id<MTLTexture> artwork, id<MTLTexture> sound,
                                     id<MTLTexture> previous);

// The strip feeds the styles read. The lyrics texture is four rows of one line each -- the
// line before, the current, the next, the one after -- updated per frame; the style pass binds
// it at [[texture(5)]]. The text texture is three rows (before, current, next) for the shaders'
// `text` input, with TextAspect giving each row's advance over its height (x, x, x, 1) and
// TextReady saying rows are there at all.
id<MTLTexture> SGRLyricsShaderLyricsTexture(void);
id<MTLTexture> SGRLyricsShaderTextTexture(void);
void SGRLyricsShaderTextAspect(float * _Nonnull out);
BOOL SGRLyricsShaderTextReady(void);

// Fills the lyrics tail of a style frame: the 1920 bytes the compiled-in styles compile
// against, whose first 304 are the renderer's own SGRShaderFrame. Offsets in the tail: 304
// lyricsReady, 308 lyricsTiming, 312 lyricIndex, 316 lyricCount, 320 lyricLines float4[4]
// (start, end, width in em, word count, one row a line), 384 lyricWords float4[96] (24 a row:
// x0, x1 in em, start, end in seconds). The caller memcpys its 304-byte head first, then this
// fills from offset 304 on; `size` is the caller's whole frame, 1920 to fill the tail entire.
void SGRLyricsShaderFillStyleFrame(void *frame, size_t size);

// The values the user has set on a style's params, as the manifest holds them: a number for a
// float, a BOOL for a toggle, a hex string for a colour. Unset params answer their defaults.
// Kept under the engine's own defaults key; the Visualizer's store is separate for now.
NSDictionary<NSString *, id> *SGRLyricsShaderParamValues(NSString *identifier);
void SGRLyricsShaderSetParamValue(NSString *identifier, NSString *paramID, id value);

// Catalog lifecycle for Lyrics settings. The source file is the cache's <uuid>.json.
BOOL SGRLyricsShaderIsCatalogIdentifier(NSString *identifier);
BOOL SGRLyricsShaderIsDownloaded(NSString *identifier);
void SGRLyricsShaderDownload(NSString *identifier, void (^done)(NSError * _Nullable error));
void SGRLyricsShaderRemove(NSString *identifier);
BOOL SGRLyricsShaderIsFavourite(NSString *identifier);
void SGRLyricsShaderSetFavourite(NSString *identifier, BOOL favourite);

NS_ASSUME_NONNULL_END
