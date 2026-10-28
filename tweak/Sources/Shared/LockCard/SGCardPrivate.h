// The parts of the lock-screen card engine the renderer's files share: the tokenizer, the CSS
// value helpers, the DOM the template becomes, and the computed style one box carries. Nothing
// here imports UIKit -- the whole pipeline runs on Core Graphics and Core Text, so the Mac
// harness compiles every file except the UIKit wrapper and the settings page.
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// the render entry the UIKit wrapper and the harness both call. width and height are points,
// scale the backing pixel density; nil plus a reason on failure.
CGImageRef _Nullable SGCardRenderCG(NSString *styleID, NSDictionary *data, CGImageRef _Nullable cover,
                                    CGFloat width, CGFloat height, CGFloat scale, NSString **_Nullable errorOut);

// the styles by id, the same shape the picker reads: id, name, author, fonts (array), css,
// and template where the catalog one carries its own. ids are "builtin:classic",
// "builtin:vinyl", "builtin:messages" and "catalog:<uuid>".
NSDictionary *SGCCoreBuiltinStyles(void);
NSArray<NSDictionary *> *SGCCoreCatalogStyles(void);
void SGCCoreRefreshCatalog(void);
NSString *SGCCoreStyleID(void);
void SGCCoreSetStyle(NSString *styleID);
void SGCCoreRegisterFontsForStyle(NSString *styleID);

#pragma mark - tokens

typedef NS_ENUM(uint8_t, SGCTokType) {
    SGCTokEOF = 0,
    SGCTokIdent,      // text: the name
    SGCTokNumber,     // number
    SGCTokDimension,  // number + unit
    SGCTokPercent,    // number, percent form
    SGCTokString,     // text: the quoted contents, unescaped
    SGCTokHash,       // text: after the '#'
    SGCTokDelim,      // text: the one character
    SGCTokComma,
    SGCTokFunc,       // text: the name; args: the balanced tokens inside the parens
};

@interface SGCTok : NSObject
+ (SGCTok *)tokWithType:(SGCTokType)type text:(NSString *)text number:(double)number unit:(NSString *)unit;
+ (SGCTok *)func:(NSString *)name args:(NSArray<SGCTok *> *)args;
@property SGCTokType type;
@property (copy) NSString *text;
@property double number;
@property (copy) NSString *unit;
@property (copy) NSArray<SGCTok *> *args;   // function arguments, commas kept
- (NSString *)debugString;
@end

// Splits a declaration's or a whole sheet's text into tokens. CSS comments are dropped.
NSArray<SGCTok *> *SGCTokenize(NSString *text);
// Prints tokens back to text, for warnings.
NSString *SGCTokensText(NSArray<SGCTok *> *tokens);

#pragma mark - values

// what a length resolves against: the card's size fixes cqw/cqh, em goes by a font size,
// and percents take the base the caller passes (a width or a height, whichever the property reads).
typedef struct {
    CGFloat cardW, cardH;
    CGFloat em;          // the font size em reads against
    CGFloat rootEm;
} SGCLenCtx;

// Resolves one length: returns whether it was a length at all. A bare number counts as a
// length of 0 where a property never takes bare numbers; SGCNumber reads those.
BOOL SGCLength(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat *out);
// calc() aware, numbers only (var(--fit), ratios).
BOOL SGCNumber(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, double *out);
// A length, a number read as points, or a percent times base; percents without a base fail.
BOOL SGCLenOrPercent(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base, CGFloat *out);

CGColorRef _Nullable SGCColor(NSArray<SGCTok *> *tokens, CGColorRef _Nullable currentColor);
CGColorRef _Nullable SGCColorFromString(NSString *string, CGColorRef _Nullable currentColor);
CGColorRef _Nullable SGCColorFuncRGB(NSArray<SGCTok *> *args);
CGColorRef _Nullable SGCColorMix(NSArray<SGCTok *> *args, CGColorRef _Nullable currentColor);
// One gradient stop's tokens: a colour, then one or two positions. Appends to the arrays.
BOOL SGCColorStop(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base,
                  CGColorRef *_Nullable colorOut, CGFloat *_Nullable firstOut, CGFloat *_Nullable secondOut);
// Splits a token list on top-level commas: gradient stops, family lists, :is groups.
NSArray<NSArray<SGCTok *> *> *SGCSplitCommas(NSArray<SGCTok *> *tokens);
// Unwraps one bare paren group the tokenizer made of ( ... ), else the list unchanged.
NSArray<SGCTok *> *SGCStrip(NSArray<SGCTok *> *tokens);
// Replaces every var(--x, fallback?) with the tokens the element's custom properties hold.
// Unresolvable vars come back nil, which makes the whole value fail.
NSArray<SGCTok *> * _Nullable SGCExpandVars(NSArray<SGCTok *> *tokens,
                                            NSDictionary<NSString *, NSArray<SGCTok *> *> *vars);

#pragma mark - selectors and rules

@interface SGCAttrTest : NSObject
@property (copy) NSString *name, *value;
@property char op;   // 0 presence, '=' exact, '^' prefix, '$' suffix, '*' contains
@end

@interface SGCCompound : NSObject
@property unichar combinator;   // how this compound joins the one before: ' ' descendant, '>' child, '+' or '~' sibling
@property (copy) NSString *tag; // nil matches any element
@property (copy) NSArray<NSString *> *classes;
@property (copy) NSArray<SGCAttrTest *> *attrs;
// entries: @"lang:ja", @"nth:3n+1", @"nth:even", @"last-child", @"first-child"
@property (copy) NSArray<NSString *> *pseudos;
// parallel to the pseudos that take selectors: the :is / :not groups, each a list of
// compound sequences as rules parse them
@property (copy) NSArray<NSArray<SGCCompound *> *> *nested;
@property NSUInteger specificity;   // classes + attribute tests + pseudos + tags
@property BOOL hasTag;
@end

@interface SGCDecl : NSObject
+ (SGCDecl *)decl:(NSString *)prop value:(NSArray<SGCTok *> *)tokens important:(BOOL)important;
@property (copy) NSString *prop;          // lowercased; custom properties keep their case
@property (copy) NSArray<SGCTok *> *value;
@property BOOL important;
@end

@interface SGCRule : NSObject
@property (copy) NSArray<SGCCompound *> *selector;   // left to right
@property (copy) NSString *pseudoName;               // @"before" / @"after" when the last compound is one
@property (copy) NSArray<SGCDecl *> *decls;
@property NSUInteger specificity;
@property NSInteger sheet;    // 0 the engine's own sheet, 1 the style's, 2 a catalog extra; a tiebreak after specificity
@property NSInteger order;    // position across every sheet, later wins at equal specificity
@end

// Parses one stylesheet's text. Rules inside at-rules, or with selectors nothing here reads,
// are skipped. `order` continues across sheets so source order means UA sheet first.
NSArray<SGCRule *> *SGCParseCSS(NSString *css, NSInteger sheet, NSInteger firstOrder);

// Whether a rule's selector matches. The element's ancestors and the previous sibling come
// along on the node, self first.
@class SGCMatchNode;
BOOL SGCRuleMatches(SGCRule *rule, SGCMatchNode *node);
@interface SGCMatchNode : NSObject
+ (instancetype)nodeWithTag:(NSString *)tag classes:(NSArray<NSString *> *)classes attrs:(NSDictionary *)attrs pseudo:(NSString *)pseudo lang:(NSString *)lang;
@property (copy) NSString *tag, *pseudo, *lang;
@property (copy) NSArray<NSString *> *classes;
@property (copy) NSDictionary *attrs;
@property (weak) SGCMatchNode *parent, *prev;   // prev: the previous in-flow element sibling
@property NSInteger childIndex;                 // among the parent's in-flow element children
@property BOOL isLast;
@end

#pragma mark - the DOM

@class SGCBox, SGCStyle;

@interface SGCBox : NSObject
@property (copy) NSString *tag;                 // lowercased; @"text" for a text run
@property (copy) NSString *text;                // the run's characters, for @"text"
@property (copy) NSDictionary *attrs;
@property (strong) NSMutableArray<SGCBox *> *children;      // element boxes, in order
@property (strong) NSMutableArray *inlineItems;             // mixed: SGCBox or NSString, this box's inline content
@property (strong) SGCBox *before, *after;                  // ::before / ::after, boxes of their own
@property BOOL isPseudo;
@property BOOL isAtomic;               // an inline-block child that rides a paragraph as one box
// the cascade's winners for this box, longhand name -> decl, plus every custom property
@property (strong) NSMutableDictionary<NSString *, SGCDecl *> *decls;
@property (strong) NSMutableDictionary<NSString *, NSArray<SGCTok *> *> *customProps;
@property (strong) SGCStyle *style;
// layout: the border box in the parent's coordinates
@property CGRect frame;
// text: the paragraph this box draws, and its lines in content-box coordinates
@property (strong) NSAttributedString *textAttr;
@property (strong) NSArray *textLines;   // SGCTextLine
@property (strong) id paintExtra;        // what the painter stashes (resolved gradients and the like)
- (NSArray<NSString *> *)classList;
- (NSString *)attr:(NSString *)name;
- (void)walk:(void (^)(SGCBox *box, SGCBox *parent))block;
@end

// One laid-out line of a box's inline content.
@interface SGCTextLine : NSObject
@property CGRect bounds;        // in the box's content coordinates
@property CGFloat baseline;     // from the content box's top
@property (strong) NSMutableArray *fragments;   // SGCFragment
@end

// A stretch of one line: a run of the box's own text or one inline child's.
@interface SGCFragment : NSObject
@property NSRange range;        // in the box's attributed string
@property CGFloat x, width;     // after text-align, content-box coordinates
@property (strong) SGCBox *box; // the inline child the run belongs to, nil for the box's own text
@property BOOL lineBreak;
@end

#pragma mark - computed style

typedef NS_ENUM(uint8_t, SGCDisplay) {
    SGCDisplayNone = 0, SGCDisplayBlock, SGCDisplayFlex, SGCDisplayInline, SGCDisplayInlineBlock,
};
typedef NS_ENUM(uint8_t, SGCDir) { SGCDirRow = 0, SGCDirColumn };
typedef NS_ENUM(uint8_t, SGCPack) { SGCPackStart = 0, SGCPackCenter, SGCPackEnd, SGCPackBetween, SGCPackAround };
typedef NS_ENUM(uint8_t, SGCAlign) { SGCAlignStretch = 0, SGCAlignStart, SGCAlignCenter, SGCAlignEnd };
typedef NS_ENUM(uint8_t, SGCTextAlign) { SGCTextLeft = 0, SGCTextCenter, SGCTextRight };
typedef NS_ENUM(uint8_t, SGCTextForm) { SGCTextAsIs = 0, SGCTextUpper, SGCTextLower };

// A gradient the painter turns into a CGGradient with the box's size at hand. Stops come as
// parallel arrays: a position is a fraction of the gradient line, or a point count when the
// style wrote one; NAN marks absence.
@interface SGCGradient : NSObject
@property (copy) NSArray *colors;    // CGColorRef boxed as pointers; the style owns the colours
@property (copy) NSArray<NSNumber *> *stopsPt;       // points along the line
@property (copy) NSArray<NSNumber *> *stopsFraction; // fractions of the line, NAN where the stop had none
@property uint8_t kind;          // 0 linear, 1 radial, 2 conic
@property BOOL repeating;
@property double angle;          // css degrees: 0 points up, clockwise
@property CGPoint center;        // radial/conic: fraction of the box
@property CGFloat radiusX, radiusY;
@property double from;           // conic start, css degrees
@end

// One background layer: the colour sits on the style; a layer is an image source (a gradient
// or the cover marker) with position, size and repeat.
@interface SGCBGLayer : NSObject
@property (strong) SGCGradient *gradient;
@property BOOL coverImage;             // --cover: the artwork
@property CGPoint position;            // fraction of the box, after the keywords are read
@property uint8_t sizeKind;            // 0 explicit, 1 cover (aspect fill), 2 contain
@property CGSize size;                 // explicit, fractions of the box
@property BOOL repeatNone;
@end

@interface SGCTextShadow : NSObject
@property CGFloat dx, dy, blur;
@property (strong) CGColorRef color;
@end

@interface SGCBoxShadow : NSObject
@property CGFloat dx, dy, blur, spread;
@property (strong) CGColorRef color;
@property BOOL inset;
@end

@interface SGCFilters : NSObject
@property CGFloat blur;        // px, 0 off
@property double brightness, saturation, contrast, hueRotate;
@property double grayscale, sepia, invert;   // 0..1 amounts
@end

@interface SGCClipPath : NSObject
@property uint8_t kind;   // 0 polygon, 1 svg path
@property (copy) NSArray<SGCTok *> *raw;   // the points or the path, resolved against the box at paint
@end

@interface SGCMask : NSObject
@property (strong) SGCGradient *gradient;   // the fading linear form
@property BOOL dots;                        // the tiled radial dots form
@property CGSize tileSize;
@property (copy) NSArray<SGCTok *> *raw;    // the original tokens, for the painter
@end

// Everything computed about one box, lengths in points. The cascade resolves against the card,
// so a --fit pass recomputes it all.
@interface SGCStyle : NSObject
@property SGCDisplay display;
@property uint8_t position;      // 0 static, 1 relative, 2 absolute
@property UIEdgeInsets padding, margin;
@property BOOL marginLeftAuto, marginRightAuto;
// absolute positioning: has* say which insets the sheet set
@property BOOL hasLeft, hasTop, hasRight, hasBottom;
@property CGFloat left, top, right, bottom;
@property BOOL widthSet, heightSet, maxWSet, maxHSet, minWSet, minHSet;
@property CGFloat width, height, maxWidth, maxHeight, minWidth, minHeight;
@property SGCDir direction;
@property SGCPack justify;
@property SGCAlign align, selfAlign;
@property BOOL selfAlignSet;
@property CGFloat gapRow, gapColumn;
@property BOOL wrap;
@property CGFloat grow;
@property CGFloat shrink;
@property BOOL basisSet;
@property CGFloat basis;
@property NSInteger order;
// text
@property (strong) CTFontRef font;
@property CGFloat fontSize, lineHeight;    // lineHeight 0: the font's own
@property (strong) CGColorRef color;
@property CGFloat letterSpacing;
@property SGCTextAlign textAlign;
@property SGCTextForm textForm;
@property BOOL nowrap, balance, breakWords;
// paint
@property (strong) CGColorRef backgroundColor;
@property (copy) NSArray<SGCBGLayer *> *bgLayers;
@property (copy) NSArray<SGCTextShadow *> *textShadows;
@property (copy) NSArray<SGCBoxShadow *> *boxShadows;
@property CGFloat radiusTL, radiusTR, radiusBR, radiusBL;   // per corner; with hasPercentRadius these are fractions of the box
@property BOOL hasPercentRadius;
@property CGFloat borderTop, borderRight, borderBottom, borderLeft;
@property (strong) CGColorRef borderColor;
@property char borderStyle;       // 's' solid, 'd' dashed, 0 none
@property CGFloat opacity;
@property BOOL overflowHidden, hidden;   // hidden: visibility
@property NSInteger z;           // NSIntegerMin: no z-index
@property (strong) SGCFilters *filters;
@property (copy) NSArray<NSValue *> *transform;   // [@(op), a, b, c, d] resolved at paint
@property (copy) NSArray<SGCTok *> *transformRaw;
@property double rotateProp;      // the `rotate:` property, degrees
@property uint8_t blend;          // mix-blend-mode as a CGBlendMode
@property uint8_t bgBlend;        // background-blend-mode of the image layer
@property (strong) SGCClipPath *clip;
@property (strong) SGCMask *mask;
@property (copy) NSString *content;    // a pseudo's resolved content, nil without one
@property BOOL textDecoration;         // underline
@property CGFloat textIndent;
@property CGFloat wordSpacing;
@property (strong) NSMutableArray *owned;   // CF objects the style made and must outlive
@end

// Ties a +1 Core Foundation reference to a style's lifetime; returns the object back.
id SGCTakeCF(SGCStyle *style, CFTypeRef ref);
CGColorRef _Nullable SGCStyleColor(SGCStyle *style, CGColorRef _Nullable color);
CTFontRef SGCStyleFont(SGCStyle *style, CTFontRef font);

// What one render carries: the card's geometry, the artwork the --cover marker resolves to,
// and the warnings the pipeline collects.
@interface SGCCtx : NSObject
@property CGFloat cardW, cardH, scale;
@property (strong) CGImageRef cover;
@property (copy) NSMutableArray<NSString *> *warnings;
@property CGFloat safeTop, safeBottom;
@property (strong) NSMutableDictionary<NSString *, CTFontRef> *fontCache;
@property (strong) id ci;   // a CIContext for this render, made lazily (typed id here to keep UIKit out of the core)
@end

// A font for a font declaration's family list, weight 100..900, italic, at a size. system-ui
// maps to the system font, the generic families to fonts the OS carries, and named families to
// the FontCatalog's when installed.
CTFontRef SGCFontForFamilies(NSArray<NSString *> *families, CGFloat size, NSInteger weight, BOOL italic);

// Parses one gradient function's tokens. Colours are registered on the style so they outlive
// the parse; positions come back per stop as fractions or points.
SGCGradient * _Nullable SGCGradientParse(SGCTok *func, SGCLenCtx ctx, SGCStyle *owner);

#pragma mark - the pipeline's passes

// What the renderer drives: one cascade over the tree with these seed variables, one layout
// into the card, and the paint of the laid tree. The fit loop in SGCardCore.m calls the first
// two repeatedly, shrinking --fit until the .line fits its box.
void SGCCascade(SGCBox *root, NSArray<SGCRule *> *rules,
                NSDictionary<NSString *, NSArray<SGCTok *> *> *seedVars, SGCCtx *ctx);
CGSize SGCLayoutTree(SGCBox *root, SGCCtx *ctx);
void SGCPaintTree(SGCBox *root, CGContextRef ctx, SGCCtx *env);

// The laid paragraph's height and its unwrapped width, for the fit search.
CGFloat SGCTextHeight(SGCBox *box);
CGFloat SGCTextNaturalWidth(SGCBox *box);

#pragma mark - the template

// Mustache over the data dictionary: {{x}} escaped, {{{x}}} raw, {{#x}} sections (arrays
// iterate, dictionaries push a scope), {{^x}} inverted. Unknown names render nothing, with a warning.
NSString *SGCMustache(NSString *templateText, NSDictionary *data, NSMutableArray<NSString *> *warnings);
// The HTML subset to a box tree. Disallowed tags come out as spans, script and style are dropped.
SGCBox *SGCParseHTML(NSString *html, NSMutableArray<NSString *> *warnings);

// The template the builtins and catalog entries without one of their own share.
NSString *SGCardDefaultTemplate(void);
// The engine's own sheet, before every style's.
NSString *SGCardUserAgentCSS(void);

NS_ASSUME_NONNULL_END
