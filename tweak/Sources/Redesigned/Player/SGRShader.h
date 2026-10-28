// The Visualizer's shaders: what the Visualizer background (PlayerVisualiser.m) draws when the sound
// calls for more than the two hills -- little Metal programs, three of them compiled in and more
// brought in from the asset catalog (Shared/Catalog), each fed the same frame of the song: the
// spectrum and the waveform on a sound texture, the cover, the frame it drew last, and the clock.
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

#define SGRKeyVisualiserShader       @"spotifyglass.redesign.visualizer.shader"  // a shader id, "builtin:bars" until set
#define SGRKeyVisualiserShaderParams @"spotifyglass.redesign.visualizer.shader.params" // { shader id: { param id: value } }
#define SGRKeyVisualiserShuffle      @"spotifyglass.redesign.visualizer.shuffle"

extern NSNotificationName const SGRShaderDidChangeNotification;

// One shader of the catalog or one of the compiled-in ones, telling what it is drawn as and what it
// wants to be fed. The objects are made once and answer for the process's life.
@interface SGRShaderInfo : NSObject
@property (nonatomic, readonly) NSString *identifier;   // "builtin:bars", or "cat:<uuid>@<version>"
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *detail;       // a line about what it draws, may be empty
@property (nonatomic, readonly) NSString *author;       // who wrote it, empty for a compiled-in one
@property (nonatomic, readonly) NSInteger fps;          // the most it asks to run at, 30, 60 or 120
@property (nonatomic, readonly) CGFloat scale;          // the share of the screen it renders at, 0.25 to 1
@property (nonatomic, readonly) BOOL builtin;
// Whether the engine can feed everything it asks for. A shader that wants the lyrics or the Canvas
// clip drawn into a texture waits until the engine learned to; the Visualizer offers only these.
@property (nonatomic, readonly) BOOL supported;
// What it wants beyond the frame: "previous" for its last frame, "tilt" for head motion, "clip" for
// the Canvas, "lyrics"/"text"/"lineMap" for words on a texture. Nothing here is required to run.
@property (nonatomic, readonly) NSArray<NSString *> *uses;
// Its adjustable values, each {"id","label","type","default"} with min/max/step for a float, empty
// for the compiled-in ones.
@property (nonatomic, readonly) NSArray<NSDictionary *> *params;
@end

// What the field and the Player page ask of a Visualizer view -- the hills' and a shader host's
// alike, so whoever shows one never says which is up (PlayerVisualiser.m keeps one of each).
@protocol SGRVisualiserShowing <NSObject>
@property (nonatomic, readonly) BOOL blurred;
- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated;
- (void)appear:(BOOL)animated;
- (void)disappear:(void (^)(void))done;
@end

@class SGRShaderInfo;

// The Metal host of one shader (SGRShaderView.m): a view filling its frame with the shader's every
// frame, appearing and disappearing as one, the lyrics' blur over it as the hills hold theirs.
@interface SGRShaderView : UIView <SGRVisualiserShowing>
- (instancetype)initWithShader:(SGRShaderInfo *)shader;
@property (nonatomic, readonly) SGRShaderInfo *shader;
@end
// The compiled-in ones first, then the catalog's kept from before, the catalog fetched again in the
// background on the first ask. Only supported shaders are listed.
NSArray<SGRShaderInfo *> *SGRShaders(void);
// Asks the catalog for its list again. The change notification says when it answers.
void SGRShaderRefreshCatalog(void);
// The shader the Visualizer draws, "builtin:bars" until chosen otherwise; a catalog entry since taken
// out of the catalog, or one the engine cannot feed, answers the compiled-in bars instead.
SGRShaderInfo *SGRShaderChosen(void);
void SGRShaderChoose(SGRShaderInfo *shader);
// Whether this iPhone can draw shaders at all. NO answers for the hills instead.
BOOL SGRShaderMetalAvailable(void);

// Its Metal source: the compiled-in ones at once, a catalog entry fetched on the first ask and kept.
// `done` runs on the main queue, with nil and a reason when it could not be had.
void SGRShaderLoadSource(SGRShaderInfo * _Nullable shader, void (^done)(NSString * _Nullable source));

// The values the user has set on a shader's params, as the manifest holds them: a number for a float,
// a BOOL for a toggle, a hex string for a colour. Unset params answer their defaults.
NSDictionary<NSString *, id> *SGRShaderParamValues(SGRShaderInfo *shader);
void SGRShaderSetParamValue(SGRShaderInfo * _Nullable shader, NSString *paramID, id _Nullable value);

// The Player page's two pages: the shader picker, and the chosen shader's params. `owner` is the page
// they are pushed from, so picking a shader can come back to it.
UIViewController *SGRShaderPickerPage(UIViewController *owner);
UIViewController *SGRShaderParamsPage(UIViewController *owner);

// Where the Canvas clip's frames come from: a block answering the pixel buffer being played now
// (retained for the caller), or nil when nothing plays. PlayerMotion.x installs its player's output
// here at launch; the shaders with a "clip" input draw it, and without it they draw the cover.
void SGRShaderSetClipPixelBufferProvider(CVPixelBufferRef _Nullable (^ _Nullable provider)(void));

NS_ASSUME_NONNULL_END
