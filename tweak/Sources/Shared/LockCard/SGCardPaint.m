// The painter: boxes in z order (negatives, then flow, then positioned and positive), each one
// clipped to its rounded corners and clip-path, its background painted (colour, linear, radial
// and conic gradients with their repeating forms, the cover image aspect-filled), its borders
// and box-shadows, then its text through the fragments -- a shadow pass under the fill pass --
// with inline children drawing their own fragment backgrounds. A filter renders the subtree
// offscreen and runs it through Core Image before compositing; a mask renders offscreen and
// fades through a grayscale mask; a mix-blend-mode composites with that blend mode.
#import "SGCardPrivate.h"
#import <CoreImage/CoreImage.h>

static void paintBox(SGCBox *box, CGContextRef ctx, SGCCtx *env, CGPoint origin);

#pragma mark - small helpers

static CGContextRef bitmapContext(CGSize size, CGFloat scale, CGColorSpaceRef space, BOOL gray) {
    CGFloat w = MAX(ceil(size.width * scale), 1), h = MAX(ceil(size.height * scale), 1);
    if (gray) return CGBitmapContextCreate(NULL, w, h, 8, w, space, kCGImageAlphaNone);
    return CGBitmapContextCreate(NULL, w, h, 8, 0, space, kCGImageAlphaPremultipliedLast);
}

static void cornersOfBox(SGCStyle *s, CGRect rect, CGFloat *tl, CGFloat *tr, CGFloat *br, CGFloat *bl) {
    *tl = s.radiusTL; *tr = s.radiusTR; *br = s.radiusBR; *bl = s.radiusBL;
    if (!s.hasPercentRadius) return;
    CGFloat minSide = MIN(rect.size.width, rect.size.height);
    *tl = s.radiusTL * minSide;
    *tr = s.radiusTR * minSide;
    *br = s.radiusBR * minSide;
    *bl = s.radiusBL * minSide;
}

static CGPathRef roundedPath(CGRect rect, CGFloat tl, CGFloat tr, CGFloat br, CGFloat bl) {
    if (tl <= 0 && tr <= 0 && br <= 0 && bl <= 0) return CGPathCreateWithRect(rect, NULL);
    CGFloat minSide = MIN(rect.size.width, rect.size.height) / 2;
    tl = MIN(MAX(tl, 0), minSide);
    tr = MIN(MAX(tr, 0), minSide);
    br = MIN(MAX(br, 0), minSide);
    bl = MIN(MAX(bl, 0), minSide);
    return CGPathCreateWithRoundedRect(rect, tl, tr, br, bl, NULL);
}

#pragma mark - gradients

// Stops resolved against the line: percents as fractions, lengths as points over it, the ones
// with no position spread between their set neighbours, and the whole cycle repeated when the
// gradient repeats.
static void gradientStops(SGCGradient *g, CGFloat lineLength,
                          NSMutableArray<NSNumber *> *positions, NSMutableArray<id> *colors) {
    NSUInteger n = g.colors.count;
    if (!n) return;
    NSMutableArray<NSNumber *> *resolved = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat value = NAN;
        CGFloat fraction = g.stopsFraction[i].doubleValue;
        CGFloat pt = g.stopsPt[i].doubleValue;
        if (fraction == fraction) value = fraction;
        else if (pt == pt) value = lineLength > 0 ? pt / lineLength : 0;
        [resolved addObject:@(value)];
    }
    for (NSUInteger i = 0; i < n; i++) {
        if (resolved[i].doubleValue == resolved[i].doubleValue) continue;
        NSUInteger next = n;
        for (NSUInteger k = i + 1; k < n; k++)
            if (resolved[k].doubleValue == resolved[k].doubleValue) { next = k; break; }
        CGFloat from = i ? resolved[i - 1].doubleValue : 0;
        CGFloat to = next < n ? resolved[next].doubleValue : (i ? from : 1);
        CGFloat span = (to - from) / (CGFloat)(next - i + 1);
        resolved[i] = @(from + span);
    }
    resolved[0] = @(MIN(resolved[0].doubleValue, resolved[n - 1].doubleValue));

    if (!g.repeating || resolved[n - 1].doubleValue - resolved[0].doubleValue <= 0.0001) {
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat value = resolved[i].doubleValue;
            if (value < 0) value = 0;
            if (value > 1) value = 1;
            if (positions.count && value < positions.lastObject.doubleValue) continue;
            [positions addObject:@(value)];
            [colors addObject:(__bridge id)g.colors[i]];
        }
        if (!positions.count) {
            [positions addObject:@0];
            [colors addObject:(__bridge id)g.colors[0]];
        }
        return;
    }
    CGFloat start = resolved[0].doubleValue, end = resolved[n - 1].doubleValue;
    CGFloat cycle = end - start;
    for (NSInteger k = (NSInteger)floor(-start / cycle) - 1; k < 128; k++) {
        CGFloat offset = start + k * cycle;
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat value = offset + (resolved[i].doubleValue - start);
            if (value < -0.0001 || value > 1.0001) continue;
            if (positions.count && value <= positions.lastObject.doubleValue) continue;
            [positions addObject:@(MIN(MAX(value, 0), 1))];
            [colors addObject:(__bridge id)g.colors[i]];
        }
        if (offset > 1) break;
    }
    if (!positions.count) {
        [positions addObject:@0];
        [colors addObject:(__bridge id)g.colors[0]];
    }
}

static CGGradientRef makeGradient(SGCGradient *g, CGFloat lineLength) {
    NSMutableArray<NSNumber *> *positions = [NSMutableArray array];
    NSMutableArray<id> *colors = [NSMutableArray array];
    gradientStops(g, lineLength, positions, colors);
    if (positions.count < 2) return NULL;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors,
                                                        (__bridge const CGFloat *)positions);
    CGColorSpaceRelease(space);
    return gradient;
}

static void drawLinearGradient(SGCGradient *g, CGRect rect, CGContextRef ctx) {
    // css degrees: 0 points up, 90 right, clockwise
    double radians = (g.angle - 90) * M_PI / 180;
    CGFloat dx = sin(radians), dy = -cos(radians);
    CGFloat length = fabs(rect.size.width * dx) + fabs(rect.size.height * dy);
    CGGradientRef gradient = makeGradient(g, length);
    if (!gradient) return;
    CGPoint center = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
    CGPoint start = CGPointMake(center.x - dx * length / 2, center.y - dy * length / 2);
    CGPoint end = CGPointMake(center.x + dx * length / 2, center.y + dy * length / 2);
    CGContextDrawLinearGradient(ctx, gradient, start, end,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
}

static void drawRadialGradient(SGCGradient *g, CGRect rect, CGContextRef ctx) {
    CGPoint center = CGPointMake(rect.origin.x + g.center.x * rect.size.width,
                                 rect.origin.y + g.center.y * rect.size.height);
    CGFloat radius = 0;   // farthest corner, the css default
    for (NSUInteger corner = 0; corner < 4; corner++) {
        CGPoint point = CGPointMake(corner & 1 ? CGRectGetMaxX(rect) : CGRectGetMinX(rect),
                                    corner & 2 ? CGRectGetMaxY(rect) : CGRectGetMinY(rect));
        radius = MAX(radius, hypot(point.x - center.x, point.y - center.y));
    }
    CGGradientRef gradient = makeGradient(g, radius);
    if (!gradient) return;
    CGContextDrawRadialGradient(ctx, gradient, center, 0, center, radius,
                                kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(gradient);
}

// A conic gradient becomes a fan of thin wedges, each filled with the stops' colours mixed at
// its middle. A hundred and eighty steps reads smooth at card sizes.
static void drawConicGradient(SGCGradient *g, CGRect rect, CGContextRef ctx) {
    NSUInteger n = g.colors.count;
    if (!n) return;
    CGPoint center = CGPointMake(rect.origin.x + g.center.x * rect.size.width,
                                 rect.origin.y + g.center.y * rect.size.height);
    CGFloat radius = hypot(rect.size.width, rect.size.height) / 2 * 1.5 + 2;
    NSMutableArray<NSNumber *> *fractions = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat value = g.stopsFraction[i].doubleValue;
        if (value != value) value = g.stopsPt[i].doubleValue / MAX(radius, 1);
        [fractions addObject:@(MIN(MAX(value, 0), 1))];
    }
    const int steps = 180;
    for (int step = 0; step < steps; step++) {
        CGFloat t = ((CGFloat)step + 0.5) / steps;
        NSUInteger index = 0;
        while (index + 1 < n && fractions[index + 1].doubleValue <= t) index++;
        CGFloat a0 = fractions[index].doubleValue;
        CGFloat a1 = index + 1 < n ? fractions[index + 1].doubleValue : 1;
        CGFloat local = a1 > a0 ? (t - a0) / (a1 - a0) : 0;
        local = MIN(MAX(local, 0), 1);
        CGColorRef c0 = (__bridge CGColorRef)g.colors[index];
        CGColorRef c1 = (__bridge CGColorRef)g.colors[MIN(index + 1, n - 1)];
        NSUInteger k0 = CGColorGetNumberOfComponents(c0), k1 = CGColorGetNumberOfComponents(c1);
        const CGFloat *v0 = CGColorGetComponents(c0), *v1 = CGColorGetComponents(c1);
        CGFloat r0 = k0 >= 3 ? v0[0] : v0[0], g0 = k0 >= 3 ? v0[1] : v0[0], b0 = k0 >= 3 ? v0[2] : v0[0];
        CGFloat a0c = k0 == 2 ? v0[1] : (k0 >= 4 ? v0[3] : 1);
        CGFloat r1 = k1 >= 3 ? v1[0] : v1[0], g1 = k1 >= 3 ? v1[1] : v1[0], b1 = k1 >= 3 ? v1[2] : v1[0];
        CGFloat a1c = k1 == 2 ? v1[1] : (k1 >= 4 ? v1[3] : 1);
        CGFloat mix[4] = {r0 + (r1 - r0) * local, g0 + (g1 - g0) * local, b0 + (b1 - b0) * local, a0c + (a1c - a0c) * local};
        CGContextSetRGBFillColor(ctx, mix[0], mix[1], mix[2], mix[3]);

        CGFloat from = (g.from - 90) * M_PI / 180;
        CGFloat start = from + t * 2 * M_PI, end = from + (t + 1.0 / steps) * 2 * M_PI + 0.002;
        CGMutablePathRef wedge = CGPathCreateMutable();
        CGPathMoveToPoint(wedge, NULL, center.x, center.y);
        CGPathAddArc(wedge, NULL, center.x, center.y, radius, start, end, NO);
        CGPathCloseSubpath(wedge);
        CGContextAddPath(ctx, wedge);
        CGContextFillPath(ctx);
        CGPathRelease(wedge);
    }
}

#pragma mark - background

// CG images draw bottom-up and this engine's coordinates run top-down, so an image goes in
// through a local flip.
static void drawImageFlipped(CGImageRef image, CGRect rect, CGContextRef ctx) {
    CGContextSaveGState(ctx);
    CGContextTranslateCTM(ctx, rect.origin.x, rect.origin.y + rect.size.height);
    CGContextScaleCTM(ctx, 1, -1);
    CGContextDrawImage(ctx, CGRectMake(0, 0, rect.size.width, rect.size.height), image);
    CGContextRestoreGState(ctx);
}

static void drawCoverLayer(SGCBGLayer *layer, CGRect rect, CGContextRef ctx, SGCCtx *env) {
    CGImageRef image = env.cover;
    if (!image) return;
    CGFloat imageW = CGImageGetWidth(image), imageH = CGImageGetHeight(image);
    CGFloat boxW = rect.size.width, boxH = rect.size.height;
    CGFloat drawW = boxW, drawH = boxH;
    if (layer.sizeKind == 1) {
        CGFloat scale = MAX(boxW / imageW, boxH / imageH);
        drawW = imageW * scale;
        drawH = imageH * scale;
    } else if (layer.sizeKind == 2) {
        CGFloat scale = MIN(boxW / imageW, boxH / imageH);
        drawW = imageW * scale;
        drawH = imageH * scale;
    } else if (layer.sizeKind == 0 && layer.size.width > 0) {
        drawW = layer.size.width;
        drawH = layer.size.height > 0 ? layer.size.height : drawW;
    }
    CGFloat x = rect.origin.x + (boxW - drawW) * layer.position.x;
    CGFloat y = rect.origin.y + (boxH - drawH) * layer.position.y;
    drawImageFlipped(image, CGRectMake(x, y, drawW, drawH), ctx);
}

static void drawBackground(SGCBox *box, CGRect rect, CGContextRef ctx, SGCCtx *env) {
    SGCStyle *s = box.style;
    if (s.backgroundColor) {
        CGContextSetFillColorWithColor(ctx, s.backgroundColor);
        CGContextFillRect(ctx, rect);
    }
    for (SGCBGLayer *layer in s.bgLayers) {
        CGContextSaveGState(ctx);
        if (s.bgBlend) CGContextSetBlendMode(ctx, (CGBlendMode)s.bgBlend);
        if (layer.gradient) {
            if (layer.gradient.kind == 0) drawLinearGradient(layer.gradient, rect, ctx);
            else if (layer.gradient.kind == 1) drawRadialGradient(layer.gradient, rect, ctx);
            else if (layer.gradient.kind == 2) drawConicGradient(layer.gradient, rect, ctx);
        } else if (layer.coverImage) {
            drawCoverLayer(layer, rect, ctx, env);
        }
        CGContextRestoreGState(ctx);
    }
}

#pragma mark - clip paths

// polygon(x y, x y, ...): fractions or points of the box
static CGPathRef polygonPath(NSArray<SGCTok *> *points, CGRect rect) {
    CGMutablePathRef path = CGPathCreateMutable();
    NSUInteger index = 0;
    for (NSArray<SGCTok *> *group in SGCSplitCommas(points)) {
        NSMutableArray<SGCTok *> *pair = [NSMutableArray array];
        for (SGCTok *t in group)
            if (t.type == SGCTokDimension || t.type == SGCTokNumber || t.type == SGCTokPercent ||
                t.type == SGCTokFunc) [pair addObject:t];
        if (pair.count < 2) continue;
        CGFloat x = 0, y = 0;
        SGCLenCtx ctx = {rect.size.width, rect.size.height, 0, 0};
        SGCLenOrPercent(@[pair[0]], ctx, rect.size.width, &x);
        SGCLenOrPercent(@[pair[1]], ctx, rect.size.height, &y);
        CGPoint point = CGPointMake(rect.origin.x + x, rect.origin.y + y);
        if (!index) CGPathMoveToPoint(path, NULL, point.x, point.y);
        else CGPathAddLineToPoint(path, NULL, point.x, point.y);
        index++;
    }
    if (!index) { CGPathRelease(path); return NULL; }
    CGPathCloseSubpath(path);
    return path;
}

// path('M0 0H30C30 22 ...'): the absolute M L H V C Z commands and their relative forms
static CGPathRef svgPath(NSString *text, CGRect rect) {
    CGMutablePathRef path = CGPathCreateMutable();
    CGFloat x = rect.origin.x, y = rect.origin.y;
    NSUInteger i = 0, len = text.length;
    unichar command = 0;
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
    auto readNumber = ^BOOL(CGFloat *out) {
        while (i < len && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:i]]) i++;
        if (i < len && [text characterAtIndex:i] == ',') i++;
        while (i < len && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[text characterAtIndex:i]]) i++;
        NSUInteger start = i;
        if (i < len && ([text characterAtIndex:i] == '-' || [text characterAtIndex:i] == '+')) i++;
        BOOL digits = NO, dot = NO;
        while (i < len) {
            unichar c = [text characterAtIndex:i];
            if (c >= '0' && c <= '9') { digits = YES; i++; continue; }
            if (c == '.' && !dot) { dot = YES; i++; continue; }
            break;
        }
        if (!digits) return NO;
        *out = [text substringWithRange:NSMakeRange(start, i - start)].doubleValue;
        return YES;
    };
    while (i < len) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) {
            command = c;
            i++;
            continue;
        }
        CGFloat value = 0;
        if (!readNumber(&value)) { i++; continue; }
        [numbers addObject:@(value)];
        // commands with a known arity flush once their numbers are in
        NSUInteger arity = 0;
        switch (command) {
            case 'M': case 'm': arity = 2; break;
            case 'L': case 'l': arity = 2; break;
            case 'H': case 'h': case 'V': case 'v': arity = 1; break;
            case 'C': case 'c': arity = 6; break;
            case 'S': case 's': case 'Q': case 'q': arity = 4; break;
            case 'T': case 't': arity = 2; break;
            case 'A': case 'a': arity = 7; break;
            default: arity = 0; break;
        }
        if (arity && numbers.count >= arity) {
            CGFloat v[7];
            for (NSUInteger k = 0; k < arity; k++) v[k] = numbers[k].doubleValue;
            [numbers removeAllObjects];
            BOOL relative = command >= 'a';
            switch ((command & ~0x20)) {
                case 'M':
                    x = relative ? x + v[0] : rect.origin.x + v[0];
                    y = relative ? y + v[1] : rect.origin.y + v[1];
                    CGPathMoveToPoint(path, NULL, x, y);
                    break;
                case 'L':
                    x = relative ? x + v[0] : rect.origin.x + v[0];
                    y = relative ? y + v[1] : rect.origin.y + v[1];
                    CGPathAddLineToPoint(path, NULL, x, y);
                    break;
                case 'H':
                    x = relative ? x + v[0] : rect.origin.x + v[0];
                    CGPathAddLineToPoint(path, NULL, x, y);
                    break;
                case 'V':
                    y = relative ? y + v[1] : rect.origin.y + v[1];
                    CGPathAddLineToPoint(path, NULL, x, y);
                    break;
                case 'C':
                    CGPathAddCurveToPoint(path, NULL,
                                          (relative ? x : rect.origin.x) + v[0],
                                          (relative ? y : rect.origin.y) + v[1],
                                          (relative ? x : rect.origin.x) + v[2],
                                          (relative ? y : rect.origin.y) + v[3],
                                          relative ? x + v[4] : rect.origin.x + v[4],
                                          relative ? y + v[5] : rect.origin.y + v[5]);
                    x = relative ? x + v[4] : rect.origin.x + v[4];
                    y = relative ? y + v[5] : rect.origin.y + v[5];
                    break;
                case 'A':
                    x = relative ? x + v[5] : rect.origin.x + v[5];
                    y = relative ? y + v[6] : rect.origin.y + v[6];
                    CGPathAddLineToPoint(path, NULL, x, y);   // arcs ride as lines; the one use is decorative
                    break;
            }
        }
    }
    CGPathCloseSubpath(path);
    return path;
}

static CGPathRef clipPathOf(SGCClipPath *clip, CGRect rect) {
    if (!clip) return NULL;
    if (clip.kind == 0) return polygonPath(clip.raw, rect);
    if (clip.kind == 1 && clip.raw.count == 1 && clip.raw[0].type == SGCTokString)
        return svgPath(clip.raw[0].text, rect);
    return NULL;
}

#pragma mark - filters and masks

static CGImageRef applyFilters(CGImageRef image, SGCFilters *f, CGFloat scale, id ciContext) {
    if (!image || !f) return image;
    CIContext *ci = ciContext ?: [CIContext contextWithOptions:nil];
    CIImage *base = [CIImage imageWithCGImage:image];
    CIImage *current = base;
    if (f.grayscale > 0) {
        CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
        [filter setValue:current forKey:kCIInputImageKey];
        [filter setValue:@(0.0) forKey:kCIInputSaturationKey];
        current = filter.outputImage;
    }
    if (f.sepia > 0) {
        CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
        [filter setValue:current forKey:kCIInputImageKey];
        [filter setValue:@(MIN(f.sepia, 1)) forKey:kCIInputIntensityKey];
        current = filter.outputImage;
    }
    if (f.hueRotate != 0) {
        CIFilter *filter = [CIFilter filterWithName:@"CIHueAdjust"];
        [filter setValue:current forKey:kCIInputImageKey];
        [filter setValue:@(f.hueRotate * M_PI / 180) forKey:kCIInputAngleKey];
        current = filter.outputImage;
    }
    if (f.brightness != 1 || f.contrast != 1 || f.saturation != 1 || (f.grayscale <= 0 && f.saturation != 1)) {
        CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
        [filter setValue:current forKey:kCIInputImageKey];
        if (f.brightness != 1) [filter setValue:@(MIN(MAX(f.brightness, 0), 2) - 1) forKey:kCIInputBrightnessKey];
        if (f.contrast != 1) [filter setValue:@(MIN(MAX(f.contrast, 0), 4)) forKey:kCIInputContrastKey];
        if (f.saturation != 1) [filter setValue:@(MIN(MAX(f.saturation, 0), 4)) forKey:kCIInputSaturationKey];
        current = filter.outputImage ?: current;
    }
    if (f.invert > 0) {
        CIFilter *filter = [CIFilter filterWithName:@"CIColorInvert"];
        [filter setValue:current forKey:kCIInputImageKey];
        current = filter.outputImage;
    }
    if (f.blur > 0) {
        CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
        [filter setValue:current forKey:kCIInputImageKey];
        [filter setValue:@(f.blur * scale / 2) forKey:kCIInputRadiusKey];
        current = filter.outputImage;
        // the blur bleeds past the edges: crop back to what the element owns
        CGFloat w = CGImageGetWidth(image), h = CGImageGetHeight(image);
        current = [current imageByCroppingToRect:CGRectMake(0, 0, w, h)];
    }
    if (!current) return image;
    CGImageRef out = [ci createCGImage:current fromRect:current.extent];
    return out ?: image;
}

// The mask's alpha, read off its colours: a fading linear gradient, or the dots form the
// catalog tiles. Comes back as a Quartz image mask (grayscale, no alpha).
static CGImageRef maskImage(SGCMask *mask, CGRect rect, CGFloat scale) {
    CGSize pixel = CGSizeMake(MAX(rect.size.width * scale, 1), MAX(rect.size.height * scale, 1));
    if (mask.dots) {
        CGSize tile = mask.tileSize.width > 0 ? mask.tileSize : CGSizeMake(10, 10);
        CGFloat cellW = MAX(tile.width * scale, 1), cellH = MAX(tile.height * scale, 1);
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = bitmapContext(CGSizeMake(rect.size.width, rect.size.height), scale, gray, YES);
        CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorBlack));
        CGContextFillRect(ctx, CGRectMake(0, 0, pixel.width, pixel.height));
        CGContextSetFillColorWithColor(ctx, CGColorGetConstantColor(kCGColorWhite));
        NSUInteger columns = (NSUInteger)ceil(pixel.width / cellW) + 1;
        NSUInteger rows = (NSUInteger)ceil(pixel.height / cellH) + 1;
        for (NSUInteger row = 0; row < rows; row++) {
            for (NSUInteger column = 0; column < columns; column++) {
                CGFloat cx = column * cellW + cellW / 2, cy = row * cellH + cellH / 2;
                CGFloat r = MIN(cellW, cellH) * 0.42;
                CGContextFillEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));
            }
        }
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        CGColorSpaceRelease(gray);
        return image;
    }
    if (mask.gradient) {
        SGCGradient *g = mask.gradient;
        NSMutableArray<id> *levels = [NSMutableArray array];
        NSMutableArray<NSNumber *> *positions = [NSMutableArray array];
        for (NSUInteger i = 0; i < g.colors.count; i++) {
            CGColorRef color = (__bridge CGColorRef)g.colors[i];
            NSUInteger count = CGColorGetNumberOfComponents(color);
            const CGFloat *v = CGColorGetComponents(color);
            CGFloat alpha = count == 2 ? v[1] : (count >= 4 ? v[3] : 1);
            CGFloat fraction = g.stopsFraction[i].doubleValue;
            CGFloat position = fraction == fraction ? fraction : (g.colors.count > 1 ? (CGFloat)i / (g.colors.count - 1) : 0);
            [levels addObject:(id)CGColorCreateGenericGray(alpha, 1)];
            [positions addObject:@(position)];
        }
        CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = bitmapContext(CGSizeMake(rect.size.width, rect.size.height), scale, gray, YES);
        CGColorSpaceRef levelSpace = CGColorSpaceCreateDeviceGray();
        CGGradientRef gradient = CGGradientCreateWithColors(levelSpace, (__bridge CFArrayRef)levels,
                                                            (__bridge const CGFloat *)positions);
        double radians = (g.angle - 90) * M_PI / 180;
        CGFloat dx = sin(radians), dy = -cos(radians);
        CGFloat length = fabs(rect.size.width * dx) + fabs(rect.size.height * dy);
        CGPoint center = CGPointMake(pixel.width / 2, pixel.height / 2);
        if (gradient && length > 0)
            CGContextDrawLinearGradient(ctx, gradient,
                                        CGPointMake(center.x - dx * length / 2, center.y - dy * length / 2),
                                        CGPointMake(center.x + dx * length / 2, center.y + dy * length / 2),
                                        kCGGradientDrawsBeforeStartLocation | kCGGradientDrawsAfterEndLocation);
        for (id level in levels) CGColorRelease((CGColorRef)level);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(levelSpace);
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        CGContextRelease(ctx);
        CGColorSpaceRelease(gray);
        return image;
    }
    return NULL;
}

#pragma mark - text

// Core Text draws y-up and this engine's coordinates run top-down, so each line goes in
// through a local flip. Shadow offsets read in the flipped space and come out negated.
static void drawTextOfBox(SGCBox *box, CGContextRef ctx, CGPoint contentOrigin) {
    if (!box.textLines.count || !box.textAttr) return;
    CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)box.textAttr);
    for (SGCTextLine *line in box.textLines) {
        // group the line's fragments by owner: the owner's background and shadows go with them
        NSUInteger at = 0;
        while (at < line.fragments.count) {
            SGCFragment *first = line.fragments[at];
            SGCBox *owner = first.box;
            NSUInteger end = at + 1;
            while (end < line.fragments.count && line.fragments[end].box == owner) end++;

            if (owner && owner.style.backgroundColor && !owner.isAtomic) {
                CGFloat left = first.x;
                SGCFragment *last = line.fragments[end - 1];
                CGRect fragmentRect = CGRectMake(contentOrigin.x + left, contentOrigin.y + line.bounds.origin.y,
                                                 last.x + last.width - left, line.bounds.size.height);
                CGFloat tl, tr, br, bl;
                cornersOfBox(owner.style, fragmentRect, &tl, &tr, &br, &bl);
                CGPathRef path = roundedPath(fragmentRect, tl, tr, br, bl);
                CGContextSetFillColorWithColor(ctx, owner.style.backgroundColor);
                CGContextAddPath(ctx, path);
                CGContextFillPath(ctx);
                CGPathRelease(path);
            }

            SGCStyle *style = owner ? owner.style : box.style;
            NSUInteger shadowCount = style.textShadows.count;
            for (NSUInteger pass = 0; pass <= shadowCount; pass++) {
                BOOL fillPass = pass == shadowCount;
                if (!fillPass) {
                    SGCTextShadow *shadow = style.textShadows[pass];
                    CGContextSetShadowWithColor(ctx, CGSizeMake(shadow.dx, -shadow.dy),
                                                shadow.blur, shadow.color);
                }
                for (NSUInteger k = at; k < end; k++) {
                    SGCFragment *piece = line.fragments[k];
                    if (piece.box && piece.box.isAtomic) continue;   // the child paints itself
                    CTLineRef subline = CTTypesetterCreateLine(typesetter,
                        CFRangeMake(piece.range.location, piece.range.length));
                    CGContextSaveGState(ctx);
                    CGContextTranslateCTM(ctx, contentOrigin.x + piece.x, contentOrigin.y + line.baseline);
                    CGContextScaleCTM(ctx, 1, -1);
                    CGContextSetTextPosition(ctx, 0, 0);
                    CTLineDraw(subline, ctx);
                    CGContextRestoreGState(ctx);
                    CTLineRelease(subline);
                }
                CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
            }
            at = end;
        }
    }
    CFRelease(typesetter);
}

#pragma mark - the box walk

// The paint order inside one container: negative z first, then the in-flow children in tree
// order, then positioned children and positive z, each group stable.
static NSArray<SGCBox *> *paintOrder(NSArray<SGCBox *> *children) {
    NSMutableArray<SGCBox *> *negative = [NSMutableArray array];
    NSMutableArray<SGCBox *> *flow = [NSMutableArray array];
    NSMutableArray<SGCBox *> *above = [NSMutableArray array];
    for (SGCBox *child in children) {
        if (!child.style || child.style.display == SGCDisplayNone) continue;
        if (child.style.z != NSIntegerMin && child.style.z < 0) { [negative addObject:child]; continue; }
        if (child.style.position == 0 && (child.style.z == NSIntegerMin || child.style.z == 0)) {
            [flow addObject:child];
            continue;
        }
        [above addObject:child];
    }
    NSComparator byZ = ^NSComparisonResult(SGCBox *a, SGCBox *b) {
        NSInteger za = a.style.z == NSIntegerMin ? 0 : a.style.z;
        NSInteger zb = b.style.z == NSIntegerMin ? 0 : b.style.z;
        return @(za).compare:@(zb);
    };
    negative = [negative sortedArrayWithOptions:NSSortStable usingComparator:byZ];
    above = [above sortedArrayWithOptions:NSSortStable usingComparator:byZ];
    NSMutableArray *all = [negative mutableCopy];
    [all addObjectsFromArray:flow];
    [all addObjectsFromArray:above];
    return all;
}

static CGAffineTransform transformOfBox(SGCBox *box, CGRect rect) {
    SGCStyle *s = box.style;
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (s.transformRaw.count) {
        for (SGCTok *t in s.transformRaw) {
            if (t.type == SGCTokDimension && [t.unit.lowercaseString isEqualToString:@"deg"]) {
                transform = CGAffineTransformRotate(transform, t.number * M_PI / 180);
                continue;
            }
            if (t.type != SGCTokFunc) continue;
            NSString *name = t.text.lowercaseString;
            CGFloat a = t.args.firstObject ? t.args.firstObject.number : 0;
            CGFloat b = t.args.count > 1 ? t.args[1].number : a;
            if ([name isEqualToString:@"scale"]) transform = CGAffineTransformScale(transform, a, b);
            else if ([name isEqualToString:@"scalex"]) transform = CGAffineTransformScale(transform, a, 1);
            else if ([name isEqualToString:@"scaley"]) transform = CGAffineTransformScale(transform, 1, a);
            else if ([name isEqualToString:@"rotate"]) {
                NSString *unit = t.args.firstObject.unit.lowercaseString;
                CGFloat radians = ([unit isEqualToString:@"turn"]) ? a * 2 * M_PI : a * M_PI / 180;
                transform = CGAffineTransformRotate(transform, radians);
            }
            else if ([name isEqualToString:@"translatex"] || [name isEqualToString:@"translate"]) {
                CGFloat x = a, y = [name isEqualToString:@"translate"] ? b : 0;
                SGCTok *first = t.args.firstObject;
                if (first.type == SGCTokPercent) x = first.number / 100.0 * rect.size.width;
                if (t.args.count > 1 && t.args[1].type == SGCTokPercent) y = t.args[1].number / 100.0 * rect.size.height;
                transform = CGAffineTransformTranslate(transform, x, y);
            }
            else if ([name isEqualToString:@"translatey"]) {
                CGFloat y = a;
                if (t.args.firstObject.type == SGCTokPercent) y = t.args.firstObject.number / 100.0 * rect.size.height;
                transform = CGAffineTransformTranslate(transform, 0, y);
            }
            else if ([name isEqualToString:@"skewx"]) transform = CGAffineTransformConcat(transform, CGAffineTransformMake(1, 0, tan(a * M_PI / 180), 1, 0, 0));
            else if ([name isEqualToString:@"skewy"]) transform = CGAffineTransformConcat(transform, CGAffineTransformMake(1, tan(a * M_PI / 180), 0, 1, 0, 0));
        }
    }
    if (s.rotateProp != 0) transform = CGAffineTransformRotate(transform, s.rotateProp * M_PI / 180);
    return transform;
}

// Everything one box draws, its own paint then its children's. Coordinates are the engine's
// top-down ones throughout; only the text and the images flip locally.
static void paintBoxInner(SGCBox *box, CGContextRef ctx, SGCCtx *env, CGPoint origin) {
    SGCStyle *s = box.style;
    CGRect rect = CGRectOffset(box.frame, origin.x, origin.y);

    CGContextSaveGState(ctx);

    if (s.overflowHidden || s.clip) {
        CGFloat tl, tr, br, bl;
        cornersOfBox(s, rect, &tl, &tr, &br, &bl);
        CGPathRef clip = roundedPath(rect, tl, tr, br, bl);
        CGContextAddPath(ctx, clip);
        CGContextClip(ctx);
        CGPathRelease(clip);
    }
    CGPathRef extra = clipPathOf(s.clip, rect);
    if (extra) {
        CGContextAddPath(ctx, extra);
        CGContextClip(ctx);
        CGPathRelease(extra);
    }

    CGAffineTransform transform = transformOfBox(box, rect);
    if (!CGAffineTransformIsIdentity(transform)) {
        // about the centre, the css default origin
        CGContextTranslateCTM(ctx, CGRectGetMidX(rect), CGRectGetMidY(rect));
        CGContextConcatCTM(ctx, transform);
        CGContextTranslateCTM(ctx, -CGRectGetMidX(rect), -CGRectGetMidY(rect));
    }

    // box-shadows under everything
    for (SGCBoxShadow *shadow in s.boxShadows) {
        if (shadow.inset) continue;
        CGFloat tl, tr, br, bl;
        cornersOfBox(s, rect, &tl, &tr, &br, &bl);
        CGPathRef path = roundedPath(rect, tl, tr, br, bl);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeMake(shadow.dx, shadow.dy), shadow.blur, shadow.color);
        CGContextSetFillColorWithColor(ctx, shadow.color);
        CGContextAddPath(ctx, path);
        CGContextFillPath(ctx);
        CGContextRestoreGState(ctx);
        CGPathRelease(path);
    }

    drawBackground(box, rect, ctx, env);

    if (s.borderStyle && (s.borderTop || s.borderRight || s.borderBottom || s.borderLeft) && s.borderColor) {
        CGContextSetStrokeColorWithColor(ctx, s.borderColor);
        CGContextSetLineWidth(ctx, 1);
        CGFloat widths[4] = {s.borderTop, s.borderRight, s.borderBottom, s.borderLeft};
        CGRect edges[4] = {
            CGRectMake(rect.origin.x, rect.origin.y, rect.size.width, s.borderTop),
            CGRectMake(rect.origin.x + rect.size.width - s.borderRight, rect.origin.y, s.borderRight, rect.size.height),
            CGRectMake(rect.origin.x, rect.origin.y + rect.size.height - s.borderBottom, rect.size.width, s.borderBottom),
            CGRectMake(rect.origin.x, rect.origin.y, s.borderLeft, rect.size.height),
        };
        for (NSUInteger edge = 0; edge < 4; edge++) {
            if (!widths[edge]) continue;
            if (s.borderStyle == 'd') CGContextSetLineDash(ctx, 0, (CGFloat[]){widths[edge] * 2, widths[edge] * 2}, 2);
            CGContextStrokeRect(ctx, edges[edge]);
            if (s.borderStyle == 'd') CGContextSetLineDash(ctx, 0, NULL, 0);
        }
    }

    // the box's own text and its inline children's backgrounds
    CGPoint contentOrigin = CGPointMake(origin.x + box.frame.origin.x + s.borderLeft + s.padding.left,
                                        origin.y + box.frame.origin.y + s.borderTop + s.padding.top);
    drawTextOfBox(box, ctx, contentOrigin);

    // children in z order
    CGPoint childOrigin = CGPointMake(origin.x + box.frame.origin.x, origin.y + box.frame.origin.y);
    for (SGCBox *child in paintOrder(box.children)) {
        if (child.style && child.style.position == 2) continue;   // painted after, against the box
        paintBox(child, ctx, env, childOrigin);
    }
    for (SGCBox *child in box.children) {
        if (!child.style || child.style.position != 2) continue;
        paintBox(child, ctx, env, childOrigin);
    }

    CGContextRestoreGState(ctx);
}

static void paintBox(SGCBox *box, CGContextRef ctx, SGCCtx *env, CGPoint origin) {
    SGCStyle *s = box.style;
    if (!s || s.display == SGCDisplayNone || s.hidden) return;
    CGRect rect = CGRectOffset(box.frame, origin.x, origin.y);
    if (rect.size.width <= 0 || rect.size.height <= 0) return;

    BOOL offscreen = s.filters != nil || s.mask != nil;

    if (!offscreen) {
        BOOL blend = s.blend != kCGBlendModeNormal;
        BOOL group = s.opacity < 1 || blend;
        if (blend) CGContextSetBlendMode(ctx, (CGBlendMode)s.blend);
        if (group) {
            CGContextBeginTransparencyLayer(ctx, NULL);
            if (s.opacity < 1) CGContextSetAlpha(ctx, s.opacity);
        }
        paintBoxInner(box, ctx, env, origin);
        if (group) CGContextEndTransparencyLayer(ctx);
        if (blend) CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        return;
    }

    // the filtered or masked subtree goes through a bitmap painted around its own origin
    CGFloat pad = s.filters && s.filters.blur > 0 ? s.filters.blur * 2 : 0;
    CGSize bitmapSize = CGSizeMake(rect.size.width + pad * 2, rect.size.height + pad * 2);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef off = bitmapContext(bitmapSize, env.scale, space, NO);
    CGColorSpaceRelease(space);
    CGContextScaleCTM(off, env.scale, env.scale);
    paintBoxInner(box, off, env, CGPointMake(origin.x - rect.origin.x + pad,
                                             origin.y - rect.origin.y + pad));

    CGImageRef image = CGBitmapContextCreateImage(off);
    CGContextRelease(off);
    image = applyFilters(image, s.filters, env.scale, env.ci);
    if (s.mask) {
        CGImageRef mask = maskImage(s.mask, CGRectMake(0, 0, bitmapSize.width, bitmapSize.height), env.scale);
        if (mask) {
            CGImageRef faded = CGImageCreateWithMask(image, mask);
            if (faded) {
                CGImageRelease(image);
                image = faded;
            }
            CGImageRelease(mask);
        }
    }
    // the bitmap was painted in this engine's coordinates and comes back the same way
    drawImageFlipped(image, CGRectMake(rect.origin.x - pad, rect.origin.y - pad,
                                      bitmapSize.width, bitmapSize.height), ctx);
    CGImageRelease(image);
}

// The root: paints the card tree into a context whose origin is the card's top left, in the
// engine's own top-down coordinates.
void SGCPaintTree(SGCBox *root, CGContextRef ctx, SGCCtx *env) {
    CGContextSaveGState(ctx);
    for (SGCBox *child in paintOrder(root.children))
        paintBox(child, ctx, env, CGPointZero);
    CGContextRestoreGState(ctx);
}
