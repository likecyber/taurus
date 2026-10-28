// The typesetter's half of the lyrics engine (SGRLyricsEngine.m): the structs the linemap's
// Metal reads, packed exactly as the lab's extracted shaders (src_00_674fcf.mtl declares them
// (the offsets proven by the lab's layout prover), and the Core Text half that
// turns SGKaraokeLine s into word and row tables and glyph rasters.
#import <UIKit/UIKit.h>
#import <simd/simd.h>
#import <stddef.h>
#import <stdint.h>
#import "Shared/Lyrics/Lyrics.h"

// The word's flag bits, what the linemap's word reader tests for.
enum {
    SGRLyricsWordJoined = 1u,     // no space before this one, the sweep runs straight through
    SGRLyricsWordEstimated = 2u,  // its times were spread across the line, not the source's own
    SGRLyricsWordRTL = 4u,        // the line reads right to left, the sweep runs the other way
    SGRLyricsWordUntimed = 8u,    // nothing is timed at all, the words only carry x positions
};

// One word of one line: x across the line's raster in pixels, times in seconds against the
// line's now. 32 bytes, and the linemap reads it back as two float4 texels.
typedef struct {
    float x0, x1, start, end;
    int32_t row, part;
    uint32_t flags;
    int32_t index;
} SGRLyricsWordRec;

// One wrapped row of one line, in the raster's pixels. 32 bytes, two more float4 texels.
typedef struct {
    float top, height, baseline;
    int32_t part;
    float x0, x1;
    int32_t firstWord, wordCount;
} SGRLyricsRowRec;

// The per-line state, set as constant buffer(1) for the vertex and the fragment both. 160
// bytes; the msl reads rect, scale, texRect, em, wordCount, now, opacity, singing and fade of
// it, the rest is carried for the styles.
typedef struct {
    vector_float4 rect;        // the slab on the target, pixels, y down
    vector_float2 size;        // the raster's size in points
    float scale;               // target pixels per raster pixel
    float fade;
    vector_float4 texRect;     // the slab in the glyph atlas, pixels
    float texelsPerPoint;
    float em;                  // the font size the raster was drawn at, points
    float index, kind, distance, state, singing, opacity;
    float start, end, duration, now, progress, sungEnd;
    float seed, side, align, blur;
    float wordCount, rowCount, activeWord, lineTiming, parts, pad;
    vector_float2 velocity;
    float nextStart, prevEnd;
} SGRLyricsLineRec;

// The linemap's frame, constant buffer(0). 976 bytes: key is float4[3] and the two sight
// arrays float4[16] each, by the msl, whatever older notes of the layout said.
typedef struct {
    vector_float2 resolution, viewSize;
    float pixelRatio, time, deltaTime;
    uint32_t frameIndex;
    vector_float4 safeArea, column;
    float anchor, position, duration, progress, playing, rate;
    float sinceTrackChange, trackSeed, lineCount, focusLine, focus, timing;
    float inBreak, nextLineIn, sinceLineChange, reduceMotion;
    vector_float4 color0, color1, color2, accent, sungColor, unsungColor;
    float dim, glow, fade, lowPower;
    vector_float4 paramSlots[4];
    vector_float2 tilt;
    float beatPhase, level, bass, mid, treble, beat, beatCount, bpm, energy, brightness;
    float motion, heard, backgroundScale, sightCount;
    vector_float4 gyro;
    vector_float4 key[3];
    vector_float4 sightRects[16], sightLines[16];
    float artworkReady, em, landscape, preview, backgroundOn;
    char tailPad[12];
} SGRLyricsFrameRec;

_Static_assert(sizeof(SGRLyricsWordRec) == 32, "the word must match the msl's word struct");
_Static_assert(sizeof(SGRLyricsRowRec) == 32, "the row must match the msl's row struct");
_Static_assert(sizeof(SGRLyricsLineRec) == 160, "the line must match the msl's line struct");
_Static_assert(sizeof(SGRLyricsFrameRec) == 976, "the frame must match the msl's lyrics frame");
_Static_assert(offsetof(SGRLyricsFrameRec, paramSlots) == 240, "paramSlots at 240");
_Static_assert(offsetof(SGRLyricsFrameRec, key) == 384, "key at 384");
_Static_assert(offsetof(SGRLyricsFrameRec, sightRects) == 432, "sightRects at 432");
_Static_assert(offsetof(SGRLyricsFrameRec, sightLines) == 688, "sightLines at 688");

// A styles' frame is the renderer's 304-byte SGRShaderFrame with the lyrics tail behind it;
// these offsets are what SGRLyricsShaderFillStyleFrame writes from.
enum {
    SGRLyricsStyleFrameSize = 1920,
    SGRLyricsStyleFrameTail = 304,       // lyricsReady
    SGRLyricsStyleFrameLyricLines = 320, // float4[4]
    SGRLyricsStyleFrameLyricWords = 384, // float4[96]
};

// One typeset line: the word and row tables in its raster's pixels, the raster itself as 8-bit
// coverage, white on black, ready to become a slab of the glyph atlas. Owned by the engine;
// made only by the typesetter.
@interface SGRLyricsTypesetLine : NSObject
@property (nonatomic, readonly) CGFloat em;          // the font size it was drawn at, points
@property (nonatomic, readonly) CGFloat widthPt;     // the laid-out width in points
@property (nonatomic, readonly) SGKaraokeTiming timing;
@property (nonatomic, readonly) NSInteger startMs;   // the line's own times, milliseconds
@property (nonatomic, readonly) NSInteger endMs;
@property (nonatomic, readonly) NSInteger sungEndMs; // when the singing of it is over
@property (nonatomic, readonly) BOOL rtl;            // the line reads right to left
- (const SGRLyricsWordRec *)words count:(NSUInteger *)count;
- (const SGRLyricsRowRec *)rows count:(NSUInteger *)count;
// The raster: coverage bytes, `stride` wide, `width` by `height` pixels; nil when the line had
// nothing to draw.
- (const uint8_t *)coverageWidth:(NSUInteger *)width height:(NSUInteger *)height stride:(NSUInteger *)stride;
@end

// Turns karaoke lines into the tables above. A config carries the style's font: a family name
// (resolved through the fonts catalog when installed, the system otherwise), a system weight
// where the family is not had, upper case or not, tracking in em.
@interface SGRLyricsTypesetter : NSObject
- (instancetype)initWithFamily:(NSString *)family weight:(CGFloat)weight italic:(BOOL)italic
                      uppercase:(BOOL)uppercase tracking:(CGFloat)tracking;
// The raster's pixels per point; 2 by default. Strip rows ask for more, to fill their row.
@property (nonatomic) CGFloat texelsPerPoint;
// A fixed raster height instead of the font's own ascent and descent, for the strip rows: the
// shaders read a strip row as the em box with the baseline three quarters down, so their
// rasters are drawn into exactly that box. 0 (the default) frames the glyphs naturally.
@property (nonatomic) CGFloat rasterHeight;
// Shrinks the glyphs inside a fixed raster (0 to 1], so a line wider than the strip still fits
// its row with the baseline where the shaders read it. 1 by default.
@property (nonatomic) CGFloat fontScale;
// Typesets each line anew; call again only when the lines, the config or the density changed.
- (NSArray<SGRLyricsTypesetLine *> *)typeset:(NSArray<SGKaraokeLine *> *)lines;
@end
