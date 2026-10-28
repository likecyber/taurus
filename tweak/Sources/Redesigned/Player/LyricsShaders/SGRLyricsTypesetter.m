// The Core Text half (SGRLyricsTypesetter.h): a karaoke line's words laid out word by word so
// every word keeps the x range its glyphs cover, timed by the line's timing, then drawn once as
// 8-bit coverage for the glyph atlas. The linemap does the per-frame colouring; this only
// measures and rasterizes, so it runs on line changes and style changes, not per frame.
#import "SGRLyricsTypesetter.h"
#import "Shared/Fonts/FontCatalog.h"
#import <CoreText/CoreText.h>

// The size everything is measured at, in points; the strips scale the rasters up, the column
// layout scales them down, and the em fields carry this number so the shaders can reason in
// points. Tracking and the fit factor are shares of it, so the size itself is free.
static const CGFloat SGRLyricsEm = 40.0;

@interface SGRLyricsTypesetLine () {
@public
    SGRLyricsWordRec *_words;
    NSUInteger _wordCount;
    SGRLyricsRowRec *_rows;
    NSUInteger _rowCount;
    uint8_t *_coverage;
    NSUInteger _width, _height, _stride;
    CGFloat _em, _widthPt;
    SGKaraokeTiming _timing;
    NSInteger _start, _end, _sungEnd;
    BOOL _rtl;
}
@end

@implementation SGRLyricsTypesetLine

@synthesize timing = _timing;
@synthesize startMs = _start;
@synthesize endMs = _end;
@synthesize sungEndMs = _sungEnd;
@synthesize rtl = _rtl;

- (void)dealloc {
    free(_words);
    free(_rows);
    free(_coverage);
}

- (const SGRLyricsWordRec *)words:(NSUInteger *)count {
    if (count) *count = _wordCount;
    return _words;
}

- (const SGRLyricsRowRec *)rows:(NSUInteger *)count {
    if (count) *count = _rowCount;
    return _rows;
}

- (const uint8_t *)coverageWidth:(NSUInteger *)width height:(NSUInteger *)height stride:(NSUInteger *)stride {
    if (width) *width = _width;
    if (height) *height = _height;
    if (stride) *stride = _stride;
    return _coverage;
}

@end

static BOOL textReadsRightToLeft(NSString *text) {
    for (NSUInteger i = 0; i < text.length; i++) {
        UTF32Char c = [text characterAtIndex:i];
        if ((c >= 0x0590 && c <= 0x05FF) || (c >= 0x0600 && c <= 0x06FF) || (c >= 0x0700 && c <= 0x074F) ||
            (c >= 0xFB50 && c <= 0xFDFF) || (c >= 0xFE70 && c <= 0xFEFF)) return YES;
    }
    return NO;
}

// The words' times where the source timed none of its own: shares of the line's span by the
// words' length in characters. Seconds, and always running forward, so the shader's sweep
// never goes backwards. The source's own word times win where it has them.
static void estimateWords(SGRLyricsWordRec *words, NSUInteger count, SGKaraokeLine *line) {
    NSInteger start = line.start, end = MAX(SGKaraokeSungEnd(line), start + 2000);
    CGFloat total = 0;
    CGFloat lengths[count];
    for (NSUInteger i = 0; i < count; i++) {
        lengths[i] = MAX((CGFloat)line.words[i].text.length, 0.5);
        total += lengths[i];
    }
    CGFloat at = start;
    for (NSUInteger i = 0; i < count; i++) {
        CGFloat next = (i + 1 == count) ? end : at + (end - start) * (lengths[i] / MAX(total, 1));
        words[i].start = at / 1000.0f;
        words[i].end = MAX(next, at + 50) / 1000.0f;
        at = next;
    }
}

@implementation SGRLyricsTypesetter {
    UIFont *_baseFont;
    CGFloat _weight;
    BOOL _uppercase;
    CGFloat _tracking;   // in em
}

// A fixed raster height for the strip rows, and the glyphs' share of it: the shaders read a
// strip row as the em box with the baseline three quarters down, so the strip rasters are
// drawn into exactly that box, and a line too wide for the strip shrinks inside it.
@synthesize rasterHeight = _rasterHeight;
@synthesize fontScale = _fontScale;

- (instancetype)initWithFamily:(NSString *)family weight:(CGFloat)weight italic:(BOOL)italic
                      uppercase:(BOOL)uppercase tracking:(CGFloat)tracking {
    if (!(self = [super init])) return nil;
    _weight = weight;
    _uppercase = uppercase;
    _tracking = tracking;
    _texelsPerPoint = 2.0;
    _fontScale = 1.0;
    if (family.length) {
        SGFontCatalogRegisterInstalled();
        if (SGFontCatalogHasFamily(family)) {
            NSArray<NSString *> *faces = [UIFont fontNamesForFamilyName:family];
            NSString *chosen = nil;
            for (NSString *face in faces) {
                BOOL faceItalic = [face.lowercaseString containsString:@"italic"] || [face.lowercaseString containsString:@"oblique"];
                if (faceItalic == italic) { chosen = face; break; }
            }
            chosen = chosen ?: faces.firstObject ?: family;
            _baseFont = [UIFont fontWithName:chosen size:SGRLyricsEm];
        }
    }
    if (!_baseFont) _baseFont = italic ? [UIFont italicSystemFontOfSize:SGRLyricsEm]
                                       : [UIFont systemFontOfSize:SGRLyricsEm weight:weight];
    if (!_baseFont) return nil;
    return self;
}

- (NSArray<SGRLyricsTypesetLine *> *)typeset:(NSArray<SGKaraokeLine *> *)lines {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) {
        SGRLyricsTypesetLine *typeset = [self typesetLine:line];
        if (typeset) [out addObject:typeset];
    }
    return out;
}

- (SGRLyricsTypesetLine *)typesetLine:(SGKaraokeLine *)line {
    if (!line.words.count) return nil;
    BOOL unspaced = SGKaraokeUnspacedScript(SGKaraokeLineText(line));

    // The line as one string, a space between the words that are not joined. Case is folded
    // word by word as the string is built, so every word's character range is the range that
    // ends up in the string even where uppercasing changes a word's length.
    NSMutableString *text = [NSMutableString string];
    NSUInteger starts[line.words.count], ends[line.words.count];
    for (NSUInteger i = 0; i < line.words.count; i++) {
        SGKaraokeWord *word = line.words[i];
        if (i && !word.joined && !unspaced) [text appendString:@" "];
        starts[i] = text.length;
        NSString *wordText = word.text ?: @"";
        [text appendString:_uppercase ? wordText.uppercaseString : wordText];
        ends[i] = text.length;
    }
    if (!text.length) return nil;

    CGFloat fontPx = SGRLyricsEm * _texelsPerPoint * (_fontScale > 0 ? _fontScale : 1.0);
    UIFont *font = [_baseFont fontWithSize:fontPx];
    if (!font) return nil;
    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSKernAttributeName: @(_tracking * fontPx),
    };
    CFAttributedStringRef attributed = (__bridge CFAttributedStringRef)
        [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef full = CTLineCreateWithAttributedString(attributed);
    if (!full) return nil;

    // Prefix widths give each word its x range; a substring line per boundary is a handful of
    // small lines, and this runs on line changes only.
    CGFloat prefix[text.length + 1];
    prefix[0] = 0;
    for (NSUInteger k = 1; k <= text.length; k++) {
        CFAttributedStringRef prefixString = CFAttributedStringCreateWithSubstring(kCFAllocatorDefault, attributed, CFRangeMake(0, k));
                CTLineRef part = prefixString ? CTLineCreateWithAttributedString(prefixString) : NULL;
                if (prefixString) CFRelease(prefixString);
        prefix[k] = part ? (CGFloat)CTLineGetTypographicBounds(part, NULL, NULL, NULL) : 0;
        if (part) CFRelease(part);
    }
    CGFloat advance = prefix[text.length];
    CGFloat ascent, descent;
    CTLineGetTypographicBounds(full, &ascent, &descent, NULL);
    if (advance <= 0) {
        CFRelease(full);
        return nil;
    }

    SGRLyricsTypesetLine *out = [SGRLyricsTypesetLine new];
    NSUInteger count = line.words.count;
    out->_words = malloc(sizeof(SGRLyricsWordRec) * count);
    out->_wordCount = count;
    out->_em = SGRLyricsEm;
    out->_timing = line.timing;
    out->_start = line.start;
    out->_end = line.end;
    out->_sungEnd = SGKaraokeSungEnd(line);
    out->_rtl = textReadsRightToLeft(text);
    out->_widthPt = advance / _texelsPerPoint;
    uint32_t extra = line.timing == SGKaraokeTimingWords ? 0u
        : (line.timing == SGKaraokeTimingLine ? (uint32_t)SGRLyricsWordEstimated
                                              : (uint32_t)(SGRLyricsWordEstimated | SGRLyricsWordUntimed));
    for (NSUInteger i = 0; i < count; i++) {
        SGRLyricsWordRec *word = &out->_words[i];
        word->x0 = prefix[starts[i]];
        word->x1 = MAX(prefix[ends[i]], word->x0 + 0.5f);
        word->start = word->end = 0;
        word->row = 0;
        word->part = 0;
        word->flags = extra;
        if (line.words[i].joined) word->flags |= SGRLyricsWordJoined;
        if (out->_rtl) word->flags |= SGRLyricsWordRTL;
        word->index = (int32_t)i;
    }
    if (line.timing != SGKaraokeTimingWords) {
        estimateWords(out->_words, count, line);
    } else {
        NSInteger last = line.start;
        for (NSUInteger i = 0; i < count; i++) {
            SGKaraokeWord *source = line.words[i];
            NSInteger from = MAX(source.start, last), to = MAX(source.end, from + 50);
            out->_words[i].start = from / 1000.0f;
            out->_words[i].end = to / 1000.0f;
            last = to;
        }
    }

    // The raster: coverage, white on black, the baseline where the caller's layout wants it.
    // A fixed raster height (the strips) puts the baseline three quarters down; otherwise the
    // font's own ascent and descent frame the glyphs with a pixel to spare.
    CGFloat height = _rasterHeight > 0 ? _rasterHeight : ascent + descent + 2;
    CGFloat baseline = _rasterHeight > 0 ? _rasterHeight * 0.75 : ascent + 1;
    NSUInteger width = (NSUInteger)ceil(advance) + 4;
    NSUInteger stride = width;
    uint8_t *coverage = calloc(stride * (NSUInteger)height, 1);
    if (!coverage) return nil;
    CGColorSpaceRef grey = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(coverage, width, (NSUInteger)height, 8, stride, grey, (CGBitmapInfo)kCGImageAlphaNone);
    if (ctx) {
        CGContextSetFillColorWithColor(ctx, UIColor.blackColor.CGColor);
        CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
        CGContextSetFillColorWithColor(ctx, UIColor.whiteColor.CGColor);
        CGContextSetTextPosition(ctx, 2, height - baseline);
        CTLineDraw(full, ctx);
        CGContextRelease(ctx);
        out->_coverage = coverage;
        out->_width = width;
        out->_height = (NSUInteger)height;
        out->_stride = stride;
    } else {
        free(coverage);
    }
    CGColorSpaceRelease(grey);
    CFRelease(full);

    out->_rows = malloc(sizeof(SGRLyricsRowRec));
    out->_rowCount = 1;
    out->_rows[0].top = 0;
    out->_rows[0].height = height;
    out->_rows[0].baseline = baseline;
    out->_rows[0].part = 0;
    out->_rows[0].x0 = 0;
    out->_rows[0].x1 = width;
    out->_rows[0].firstWord = 0;
    out->_rows[0].wordCount = (int32_t)count;
    return out;
}

@end
