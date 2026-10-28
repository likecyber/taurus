// The layout: inline content becomes one Core Text paragraph per box (word wrap, text-wrap
// balance as a width search, atomic inline-block children as run delegates), and boxes lay
// their children out block-wise or with the flex subset the styles use -- grow and shrink,
// gaps, justify and align with per-item self-align, wrap, order -- with absolute boxes placed
// against the nearest positioned ancestor. One call lays the whole tree: SGCLayoutTree.
#import "SGCardPrivate.h"

static NSAttributedStringKey const SGCOwnerAttributeName = @"SGCardOwner";

// An inline-block child measured for its run delegate.
@interface SGCAtomic : NSObject
@property (strong) SGCBox *box;
@property CGSize size;
@end

@implementation SGCAtomic
@end

static CGSize layoutBox(SGCBox *box, CGFloat availableW, CGFloat overrideW, CGFloat overrideH,
                        BOOL final, SGCCtx *ctx);
static CGFloat layoutBlocks(SGCBox *box, CGFloat contentW, BOOL final, SGCCtx *ctx);
static CGFloat layoutFlex(SGCBox *box, CGFloat contentW, BOOL final, SGCCtx *ctx);
static void layoutAbsoluteChildren(SGCBox *box, SGCCtx *ctx);
static CGFloat typesetParagraph(SGCBox *box, CGFloat contentWidth, SGCCtx *ctx);

#pragma mark - paragraph building

// Collapses the whitespace runs a template leaves, the css way: one space where there was any.
static NSString *collapsedText(NSString *text) {
    static NSRegularExpression *regex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"[ \\t\\n\\r]+" options:0 error:nil];
    });
    return [regex stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withString:@" "];
}

// text-transform rides at run build time, the way the receipt's uppercase card needs it.
static NSString *formedText(NSString *text, SGCStyle *style) {
    if (style.textForm == SGCTextUpper) return text.uppercaseString;
    if (style.textForm == SGCTextLower) return text.lowercaseString;
    return text;
}

static NSDictionary *runAttributes(SGCStyle *style, SGCBox *owner) {
    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    if (style.font) attributes[(NSString *)kCTFontAttributeName] = (__bridge id)style.font;
    if (style.color) attributes[(NSString *)kCTForegroundColorAttributeName] = (__bridge id)style.color;
    if (style.letterSpacing) attributes[(NSString *)kCTKernAttributeName] = @(style.letterSpacing);
    if (style.textDecoration)
        attributes[(NSString *)kCTUnderlineStyleAttributeName] = @(kCTUnderlineStyleSingle);
    if (owner) attributes[SGCOwnerAttributeName] = [NSValue valueWithPointer:(__bridge void *)owner];
    return attributes;
}

#pragma mark - atomic inline children

// An inline-block child rides the paragraph as an object replacement character whose advance
// and height a run delegate reports from the child's measured size.
static CGFloat atomicGetWidth(void *ref) { return ((__bridge SGCAtomic *)ref).size.width; }
static CGFloat atomicGetAscent(void *ref) { return ((__bridge SGCAtomic *)ref).size.height; }
static CGFloat atomicGetDescent(void *ref) { return 0; }
static void atomicDealloc(void *ref) { CFBridgingRelease(ref); }

static void appendAtomic(NSMutableAttributedString *out, SGCBox *child, SGCCtx *ctx) {
    CGSize size = layoutBox(child, CGFLOAT_MAX, -1, -1, NO, ctx);
    SGCAtomic *atomic = [SGCAtomic new];
    atomic.box = child;
    atomic.size = size;

    CTRunDelegateCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.version = kCTRunDelegateCurrentVersion;
    callbacks.dealloc = atomicDealloc;
    callbacks.getWidth = atomicGetWidth;
    callbacks.getAscent = atomicGetAscent;
    callbacks.getDescent = atomicGetDescent;
    CTRunDelegateRef delegate = CTRunDelegateCreate(&callbacks, (void *)CFBridgingRetain(atomic));

    NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
    attributes[(NSString *)kCTRunDelegateAttributeName] = (__bridge id)delegate;
    attributes[SGCOwnerAttributeName] = [NSValue valueWithPointer:(__bridge void *)child];
    CFRelease(delegate);
    [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\uFFFC" attributes:attributes]];
}

// Walks a box's inline items in order, adding styled runs. Inline element children contribute
// runs styled by their own computed style; a `br` breaks the line.
static void buildParagraph(SGCBox *box, NSMutableAttributedString *out, SGCCtx *ctx) {
    for (id item in box.inlineItems) {
        if ([item isKindOfClass:NSString.class]) {
            NSString *text = formedText(collapsedText(item), box.style);
            if (!text.length) continue;
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                                        attributes:runAttributes(box.style, nil)]];
            continue;
        }
        SGCBox *child = item;
        SGCDisplay display = child.style ? child.style.display : SGCDisplayInline;
        if (display == SGCDisplayNone) continue;
        if (display == SGCDisplayInlineBlock) { appendAtomic(out, child, ctx); continue; }
        if (child.isPseudo && child.style.content.length) {
            NSString *text = formedText(child.style.content, child.style);
            [out appendAttributedString:[[NSAttributedString alloc] initWithString:text
                                                                        attributes:runAttributes(child.style, child)]];
            continue;
        }
        buildParagraph(child, out, ctx);
    }
}

#pragma mark - typesetting

static NSInteger lineCountForWidth(NSAttributedString *attr, CGFloat width) {
    if (!(width > 0) || width == CGFLOAT_MAX) return 1;
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
    NSInteger count = 0;
    NSUInteger start = 0, length = attr.length;
    while (start < length) {
        NSInteger breakAt = CTTypesetterSuggestLineBreak(typesetter, start, width);
        if (breakAt <= 0) breakAt = 1;
        start += breakAt;
        count++;
        if (count > 60) break;   // a runaway paragraph is cut rather than hung on
    }
    CFRelease(typesetter);
    return MAX(count, 1);
}

static CGFloat fontLineHeight(SGCStyle *style) {
    if (style.lineHeight > 0) return style.lineHeight;
    CGFloat ascent = 0, descent = 0, leading = 0;
    if (style.font) {
        ascent = CTFontGetAscent(style.font);
        descent = CTFontGetDescent(style.font);
        leading = CTFontGetLeading(style.font);
    }
    CGFloat height = ascent + descent + leading;
    return height > 0 ? height : style.fontSize * 1.2;
}

// Typesets the box's paragraph at contentWidth, storing the lines and their fragments on the
// box. Returns the paragraph's height; the natural (unwrapped) width rides on paintExtra.
static CGFloat typesetParagraph(SGCBox *box, CGFloat contentWidth, SGCCtx *ctx) {
    NSMutableAttributedString *attr = [NSMutableAttributedString new];
    buildParagraph(box, attr, ctx);
    box.textAttr = attr;

    CGFloat lineHeight = fontLineHeight(box.style);
    CGFloat measureWidth = box.style.nowrap ? CGFLOAT_MAX : contentWidth;
    if (!(measureWidth > 0)) measureWidth = CGFLOAT_MAX;

    if (box.style.balance && !box.style.nowrap && contentWidth > 0 && measureWidth != CGFLOAT_MAX && attr.length) {
        // balance: the narrowest width that keeps the greedy line count
        NSInteger greedy = lineCountForWidth(attr, contentWidth);
        if (greedy > 1) {
            CGFloat low = contentWidth * 0.15, high = contentWidth;
            for (int step = 0; step < 8; step++) {
                CGFloat mid = (low + high) / 2;
                if (lineCountForWidth(attr, mid) <= greedy) high = mid;
                else low = mid;
            }
            measureWidth = high;
        }
    }

    NSMutableArray<SGCTextLine *> *lines = [NSMutableArray array];
    CGFloat y = 0, widest = 0;
    if (attr.length) {
        CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attr);
        NSUInteger start = 0, length = attr.length;
        while (start < length) {
            NSInteger breakAt = box.style.nowrap ? (NSInteger)(length - start)
                                                 : CTTypesetterSuggestLineBreak(typesetter, start, measureWidth);
            if (breakAt <= 0) breakAt = 1;
            CTLineRef line = CTTypesetterCreateLine(typesetter, CFRangeMake(start, breakAt));
            CGFloat ascent = 0, descent = 0, leading = 0;
            CGFloat lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            CGFloat half = (lineHeight - (ascent + descent)) / 2;
            SGCTextLine *textLine = [SGCTextLine new];
            textLine.fragments = [NSMutableArray array];
            textLine.bounds = CGRectMake(0, y, lineWidth, lineHeight);
            textLine.baseline = y + half + ascent;
            y += lineHeight;

            CGFloat align = 0;
            if (box.style.textAlign == SGCTextCenter && lineWidth < contentWidth) align = (contentWidth - lineWidth) / 2;
            else if (box.style.textAlign == SGCTextRight && lineWidth < contentWidth) align = contentWidth - lineWidth;
            textLine.bounds.origin.x = align;
            widest = MAX(widest, lineWidth);

            CFArrayRef runs = CTLineGetGlyphRuns(line);
            for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
                CTRunRef run = CFArrayGetValueAtIndex(runs, r);
                CFRange range = CTRunGetStringRange(run);
                CGFloat runX = CTLineGetOffsetForStringIndex(line, range.location);
                CGFloat runWidth = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), NULL, NULL, NULL);
                SGCFragment *fragment = [SGCFragment new];
                fragment.range = NSMakeRange(range.location, range.length);
                fragment.x = align + runX;
                fragment.width = runWidth;
                NSDictionary *attributes = (__bridge NSDictionary *)CTRunGetAttributes(run);
                NSValue *owner = attributes[SGCOwnerAttributeName];
                if (owner) fragment.box = (__bridge SGCBox *)owner.pointerValue;
                [textLine.fragments addObject:fragment];
            }
            [lines addObject:textLine];
            CFRelease(line);
            start += breakAt;
        }
        CFRelease(typesetter);
    }
    // atomic children take their frames from the fragments that carry them, in the parent's
    // own coordinates like every other child frame
    CGFloat contentX = box.style.borderLeft + box.style.padding.left;
    CGFloat contentY = box.style.borderTop + box.style.padding.top;
    for (SGCTextLine *textLine in lines) {
        for (SGCFragment *fragment in textLine.fragments) {
            if (!fragment.box || !fragment.box.isAtomic) continue;
            fragment.box.frame = CGRectMake(contentX + fragment.x,
                                            contentY + textLine.baseline - fragment.box.frame.size.height,
                                            fragment.box.frame.size.width, fragment.box.frame.size.height);
        }
    }
    box.textLines = lines;
    box.paintExtra = @{ @"natural": @(widest), @"height": @(y) };
    return y;
}

CGFloat SGCTextHeight(SGCBox *box) {
    CGFloat height = 0;
    for (SGCTextLine *line in box.textLines) height = MAX(height, CGRectGetMaxY(line.bounds));
    return height;
}

CGFloat SGCTextNaturalWidth(SGCBox *box) {
    NSNumber *natural = box.paintExtra[@"natural"];
    return natural.doubleValue;
}

#pragma mark - box layout

// Lays one box out. availableW is the width offered in border-box terms; the overrides force
// the final width or height a flex line decided. Returns the border-box size and, in Final
// mode, sets the children's frames.
static CGSize layoutBox(SGCBox *box, CGFloat availableW, CGFloat overrideW, CGFloat overrideH,
                        BOOL final, SGCCtx *ctx) {
    SGCStyle *s = box.style;
    if (!s || s.display == SGCDisplayNone) return CGSizeZero;

    CGFloat padH = s.padding.left + s.padding.right + s.borderLeft + s.borderRight;
    CGFloat padV = s.padding.top + s.padding.bottom + s.borderTop + s.borderBottom;

    CGFloat width = -1;
    if (overrideW >= 0) width = overrideW;
    else if (s.widthSet) width = s.width;

    CGFloat contentW = width >= 0 ? width - padH
                                  : (availableW == CGFLOAT_MAX ? CGFLOAT_MAX : availableW - padH);

    BOOL hasBlocks = NO, hasInline = NO;
    for (SGCBox *child in box.children) {
        if (!child.style || child.style.display == SGCDisplayNone || child.style.position == 2) continue;
        if (child.style.display == SGCDisplayFlex || child.style.display == SGCDisplayBlock) hasBlocks = YES;
    }
    if (box.inlineItems.count) hasInline = YES;

    CGFloat contentH = 0;
    if (s.display == SGCDisplayFlex) {
        contentH = layoutFlex(box, contentW, final, ctx);
    } else if (hasBlocks) {
        contentH = layoutBlocks(box, contentW, final, ctx);
        if (box.inlineItems.count) contentH += typesetParagraph(box, contentW, ctx);
    } else if (hasInline) {
        contentH = typesetParagraph(box, contentW, ctx);
    }

    CGFloat height = overrideH >= 0 ? overrideH : (s.heightSet ? s.height : contentH + padV);

    // max-content: the paragraph's natural width decides, or the widest child
    if (width < 0) {
        if (hasInline && !hasBlocks) {
            width = SGCTextNaturalWidth(box) + padH;
        } else {
            CGFloat widest = 0;
            for (SGCBox *child in box.children) {
                if (!child.style || child.style.display == SGCDisplayNone || child.style.position == 2) continue;
                widest = MAX(widest, CGRectGetMaxX(child.frame));
            }
            width = widest > 0 ? widest + (padH - s.padding.left - s.padding.right) : contentW;
        }
    }
    if (s.maxWSet && width > s.maxWidth) {
        width = s.maxWidth;
        // the paragraph was set at the wider width: set it again at the clamp
        CGFloat clampedContent = width - padH;
        if (hasInline && !hasBlocks && clampedContent > 0 && SGCTextNaturalWidth(box) + padH > width)
            contentH = typesetParagraph(box, clampedContent, ctx);
        if (overrideH < 0 && !s.heightSet) height = contentH + padV;
    }
    if (s.minWSet) width = MAX(width, s.minWidth);
    if (s.maxHSet) height = MIN(height, s.maxHeight);
    if (s.minHSet) height = MAX(height, s.minHeight);
    if (width < 0) width = MAX(availableW == CGFLOAT_MAX ? 0 : availableW, 0);

    box.frame.size = CGSizeMake(width, height);

    if (final) {
        layoutAbsoluteChildren(box, ctx);
        if (s.position == 1) {
            if (s.hasLeft) box.frame.origin.x += s.left;
            if (s.hasTop) box.frame.origin.y += s.top;
        }
    }
    return box.frame.size;
}

// Block children stack top to bottom; auto margins centre a fixed-width child. Inline
// children draw through the paragraph instead and are skipped here.
static CGFloat layoutBlocks(SGCBox *box, CGFloat contentW, BOOL final, SGCCtx *ctx) {
    SGCStyle *s = box.style;
    CGFloat y = 0;
    CGFloat contentX = s.borderLeft + s.padding.left;
    for (SGCBox *child in box.children) {
        SGCStyle *cs = child.style;
        if (!cs || cs.display == SGCDisplayNone || cs.position == 2) continue;
        if (cs.display == SGCDisplayInline || cs.display == SGCDisplayInlineBlock) continue;
        CGFloat childWidth = cs.widthSet ? cs.width : MAX(contentW - cs.margin.left - cs.margin.right, 0);
        CGSize size = layoutBox(child, childWidth, childWidth, -1, final, ctx);
        CGFloat x = contentX + cs.margin.left;
        if (cs.widthSet && cs.marginLeftAuto && cs.marginRightAuto)
            x = contentX + MAX((contentW - size.width) / 2, 0);
        child.frame = CGRectMake(x, y + s.borderTop + s.padding.top + cs.margin.top, size.width, size.height);
        y += cs.margin.top + size.height + cs.margin.bottom;
    }
    return y;
}

// The flex subset: one main axis, grow and shrink, gaps, wrap in the row direction, justify
// and align with per-item align-self, order for the sequence. Inline children blockify, the
// way css turns them into flex items.
static CGFloat layoutFlex(SGCBox *box, CGFloat contentW, BOOL final, SGCCtx *ctx) {
    SGCStyle *s = box.style;
    BOOL column = s.direction == SGCDirColumn;
    CGFloat padH = s.padding.left + s.padding.right + s.borderLeft + s.borderRight;
    CGFloat padV = s.padding.top + s.padding.bottom + s.borderTop + s.borderBottom;
    CGFloat mainAvail = column ? (s.heightSet ? s.height - padV : CGFLOAT_MAX) : contentW;

    NSMutableArray<SGCBox *> *items = [NSMutableArray array];
    NSArray<SGCBox *> *ordered = [box.children sortedArrayWithOptions:NSSortStable
                                                            comparator:^NSComparisonResult(SGCBox *a, SGCBox *b) {
        NSInteger oa = a.style ? a.style.order : 0;
        NSInteger ob = b.style ? b.style.order : 0;
        return @(oa).compare:@(ob);
    }];
    for (SGCBox *child in ordered) {
        if (!child.style || child.style.display == SGCDisplayNone || child.style.position == 2) continue;
        [items addObject:child];
    }
    if (!items.count) return 0;

    CGFloat gap = column ? s.gapRow : s.gapColumn;
    CGFloat crossGap = column ? s.gapColumn : s.gapRow;

    NSMutableArray<NSMutableArray<NSNumber *> *> *lineBases = [NSMutableArray array];
    NSMutableArray<NSMutableArray<SGCBox *> *> *lines = [NSMutableArray array];
    NSMutableArray<NSNumber *> *bases = [NSMutableArray array];
    for (SGCBox *item in items) {
        SGCStyle *cs = item.style;
        CGFloat base = -1;
        if (cs.basisSet) base = cs.basis;
        if (base < 0 && (column ? cs.heightSet : cs.widthSet)) base = column ? cs.height : cs.width;
        if (base < 0) {
            if (column) {
                CGFloat itemW = cs.widthSet ? cs.width : contentW;
                base = layoutBox(item, itemW, itemW, -1, NO, ctx).height;
            } else {
                base = layoutBox(item, mainAvail, -1, -1, NO, ctx).width;
            }
        }
        [bases addObject:@(MAX(base, 0))];
    }

    // the lines: one, or the greedy pack when the style wraps
    if (!s.wrap || column || mainAvail == CGFLOAT_MAX) {
        [lines addObject:items];
        [lineBases addObject:bases];
    } else {
        CGFloat run = 0;
        NSMutableArray<SGCBox *> *line = [NSMutableArray array];
        NSMutableArray<NSNumber *> *lineBase = [NSMutableArray array];
        for (NSUInteger i = 0; i < items.count; i++) {
            CGFloat itemWidth = bases[i].doubleValue;
            CGFloat prospective = line.count ? run + gap + itemWidth : itemWidth;
            if (line.count && prospective > mainAvail + 0.5) {
                [lines addObject:line];
                [lineBases addObject:lineBase];
                line = [NSMutableArray array];
                lineBase = [NSMutableArray array];
                run = itemWidth;
            } else {
                run = prospective;
            }
            [line addObject:items[i]];
            [lineBase addObject:bases[i]];
        }
        if (line.count) { [lines addObject:line]; [lineBases addObject:lineBase]; }
    }

    CGFloat mainExtent = 0;   // what the container's content height comes to
    for (NSUInteger li = 0; li < lines.count; li++) {
        NSArray<SGCBox *> *line = lines[li];
        NSMutableArray<NSNumber *> *lineBase = lineBases[li];
        CGFloat sum = 0;
        for (NSNumber *base in lineBase) sum += base.doubleValue;
        sum += gap * MAX((NSInteger)line.count - 1, 0);
        CGFloat free = mainAvail == CGFLOAT_MAX ? 0 : mainAvail - sum;

        if (free > 0) {
            CGFloat totalGrow = 0;
            for (SGCBox *item in line) totalGrow += MAX(item.style.grow, 0);
            if (totalGrow > 0) {
                for (NSUInteger i = 0; i < line.count; i++)
                    lineBase[i] = @(lineBase[i].doubleValue + free * MAX(line[i].style.grow, 0) / totalGrow);
                free = 0;
            }
        } else if (free < 0) {
            CGFloat weight = 0;
            for (NSUInteger i = 0; i < line.count; i++)
                weight += lineBase[i].doubleValue * MAX(line[i].style.shrink, 0);
            if (weight > 0) {
                for (NSUInteger i = 0; i < line.count; i++) {
                    CGFloat take = -free * lineBase[i].doubleValue * MAX(line[i].style.shrink, 0) / weight;
                    lineBase[i] = @(MAX(lineBase[i].doubleValue - take, 0));
                }
            }
        }

        // final main sizes, so the cross sizes measure true
        for (NSUInteger i = 0; i < line.count; i++) {
            SGCBox *item = line[i];
            CGFloat mainSize = lineBase[i].doubleValue;
            if (column) {
                CGFloat itemW = item.style.widthSet ? item.style.width : contentW;
                layoutBox(item, itemW, itemW, mainSize, final, ctx);
            } else {
                layoutBox(item, mainSize, mainSize, -1, final, ctx);
            }
        }

        // the line's cross size: a single line in a definite container stretches, else the tallest
        CGFloat lineCross = 0;
        BOOL anyStretch = NO;
        for (SGCBox *item in line) {
            SGCStyle *cs = item.style;
            SGCAlign effective = cs.selfAlignSet ? cs.selfAlign : s.align;
            if (effective == SGCAlignStretch) anyStretch = YES;
            lineCross = MAX(lineCross, column ? item.frame.size.width : item.frame.size.height);
        }
        if (!column && mainAvail != CGFLOAT_MAX && lines.count == 1 && anyStretch && s.heightSet)
            lineCross = s.height - padV;

        for (SGCBox *item in line) {
            SGCStyle *cs = item.style;
            SGCAlign effective = cs.selfAlignSet ? cs.selfAlign : s.align;
            if (effective != SGCAlignStretch) continue;
            if (column) {
                if (!cs.widthSet && lineCross > 0)
                    layoutBox(item, lineCross, lineCross, item.frame.size.height, final, ctx);
            } else {
                if (!cs.heightSet && lineCross > 0)
                    layoutBox(item, item.frame.size.width, item.frame.size.width, lineCross, final, ctx);
            }
        }

        // main-axis positions per justify
        CGFloat used = gap * MAX((NSInteger)line.count - 1, 0);
        for (NSNumber *base in lineBase) used += base.doubleValue;
        CGFloat leftover = mainAvail == CGFLOAT_MAX ? 0 : mainAvail - used;
        CGFloat cursor = 0, extra = 0;
        if (s.justify == SGCPackCenter) cursor = leftover / 2;
        else if (s.justify == SGCPackEnd) cursor = leftover;
        else if (s.justify == SGCPackBetween && line.count > 1) extra = leftover / (line.count - 1);
        else if (s.justify == SGCPackAround) { extra = leftover / line.count; cursor = extra / 2; }

        CGFloat contentX = s.borderLeft + s.padding.left;
        CGFloat contentY = s.borderTop + s.padding.top;
        for (NSUInteger i = 0; i < line.count; i++) {
            SGCBox *item = line[i];
            SGCStyle *cs = item.style;
            SGCAlign effective = cs.selfAlignSet ? cs.selfAlign : s.align;
            CGFloat mainPos = cursor;
            cursor += lineBase[i].doubleValue + gap + extra;
            CGFloat crossSize = column ? item.frame.size.width : item.frame.size.height;
            CGFloat crossPos = 0;
            if (effective == SGCAlignCenter) crossPos = (lineCross - crossSize) / 2;
            else if (effective == SGCAlignEnd) crossPos = lineCross - crossSize;
            if (column) item.frame.origin = CGPointMake(contentX + crossPos, contentY + mainPos);
            else item.frame.origin = CGPointMake(contentX + mainPos, contentY + crossPos);
            if (cs.position == 1) {
                if (cs.hasLeft) item.frame.origin.x += cs.left;
                if (cs.hasTop) item.frame.origin.y += cs.top;
            }
        }
        mainExtent += (column ? sum : lineCross) + (li + 1 < lines.count ? crossGap : 0);
    }
    return mainExtent;
}

// Absolute boxes read their insets against the nearest positioned ancestor's padding box;
// that ancestor is found on the way down, so each container handles its own absolute set.
static void layoutAbsoluteChildren(SGCBox *box, SGCCtx *ctx) {
    SGCStyle *s = box.style;
    for (SGCBox *child in box.children) {
        SGCStyle *cs = child.style;
        if (!cs || cs.position != 2 || cs.display == SGCDisplayNone) continue;
        CGFloat padW = box.frame.size.width - s.borderLeft - s.borderRight;
        CGFloat padH = box.frame.size.height - s.borderTop - s.borderBottom;

        CGFloat width = -1;
        if (cs.hasLeft && cs.hasRight) width = padW - cs.left - cs.right - cs.margin.left - cs.margin.right;
        else if (cs.widthSet) width = cs.width;
        CGFloat height = -1;
        if (cs.hasTop && cs.hasBottom) height = padH - cs.top - cs.bottom - cs.margin.top - cs.margin.bottom;
        else if (cs.heightSet) height = cs.height;

        CGSize size = layoutBox(child, width >= 0 ? width : padW, width, height, YES, ctx);

        CGFloat x = s.borderLeft, y = s.borderTop;
        if (cs.hasLeft) x += cs.left + cs.margin.left;
        else if (cs.hasRight) x += padW - cs.right - size.width - cs.margin.right;
        if (cs.hasTop) y += cs.top + cs.margin.top;
        else if (cs.hasBottom) y += padH - cs.bottom - size.height - cs.margin.bottom;
        child.frame = CGRectMake(x, y, size.width, size.height);
    }
}

// The root pass: the tree laid into the card. The root box itself is transparent; the .card
// child carries the UA sheet's full-card size.
CGSize SGCLayoutTree(SGCBox *root, SGCCtx *ctx) {
    root.frame = CGRectMake(0, 0, ctx.cardW, ctx.cardH);
    CGFloat y = 0;
    for (SGCBox *child in root.children) {
        if (!child.style || child.style.display == SGCDisplayNone) continue;
        CGSize size = layoutBox(child, ctx.cardW, -1, -1, YES, ctx);
        child.frame = CGRectMake(0, y, size.width, size.height);
        y += size.height;
    }
    return CGSizeMake(ctx.cardW, y);
}
