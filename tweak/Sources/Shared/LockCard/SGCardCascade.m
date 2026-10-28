// The cascade: winners per longhand (importance, then specificity, then source order, inline
// style above all), custom properties inherited down the tree, and the computed style with
// every length resolved against the card. Also the font resolution and the gradient, shadow,
// filter and clip parsers that the computed style needs.
#import "SGCardPrivate.h"
#import "Shared/Fonts/FontCatalog.h"

// The catalog's family check and registration live in FontCatalog.m on the phone; its header
// imports UIKit, so the two entry points the engine needs are declared here instead.
extern BOOL SGFontCatalogHasFamily(NSString *family);
extern void SGFontCatalogRegisterInstalled(void);

#pragma mark - decl ranks

static CGFloat lengthOfToken(SGCTok *token, SGCLenCtx ctx);

@interface SGCDecl ()
@property NSUInteger rankSpec;
@property NSInteger rankOrder;
@end

@implementation SGCBox
- (NSArray<NSString *> *)classList {
    NSString *raw = self.attrs[@"class"];
    if (!raw.length) return @[];
    return [raw componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSString *)attr:(NSString *)name {
    return self.attrs[name];
}

- (void)walk:(void (^)(SGCBox *box, SGCBox *parent))block {
    [self walk:self parent:nil block:block];
}

- (void)walk:(SGCBox *)box parent:(SGCBox *)parent block:(void (^)(SGCBox *, SGCBox *))block {
    block(box, parent);
    for (SGCBox *child in box.children) [self walk:child parent:box block:block];
}
@end

#pragma mark - fonts

static CTFontRef fontWithTraits(CTFontRef base, CGFloat size, CTFontSymbolicTraits traits, double weightAxis) {
    if (weightAxis != 0) {
        CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(
            (__bridge CFDictionaryRef)@{(id)kCTFontTraitsAttribute: @{(id)@"CTFontWeightTrait": @(weightAxis)}});
        CTFontRef out = CTFontCreateCopyWithAttributes(base, size, NULL, descriptor);
        CFRelease(descriptor);
        return out;
    }
    if (!traits) return (CTFontRef)CFRetain(base);
    return CTFontCreateCopyWithSymbolicTraits(base, size, NULL, traits, traits);
}

// WebKit's map from the css weight steps to the system font's weight axis.
static double weightAxisOf(NSInteger weight) {
    switch (weight) {
        case 100: return -0.80;
        case 200: return -0.70;
        case 300: return -0.50;
        case 500: return 0.23;
        case 600: return 0.30;
        case 700: return 0.40;
        case 800: return 0.56;
        case 900: return 0.62;
        default: return 0;
    }
}

static CTFontRef genericFont(NSString *generic, CGFloat size, NSInteger weight, BOOL italic) {
    // the generic families map to fonts iOS carries; serif wants a bookish face
    NSArray *candidates = nil;
    if ([generic isEqualToString:@"serif"]) candidates = @[@"Georgia", @"Times New Roman", @"Times"];
    else if ([generic isEqualToString:@"monospace"]) candidates = @[@"Menlo", @"Courier New", @"Courier"];
    else if ([generic isEqualToString:@"cursive"]) candidates = @[@"Snell Roundhand", @"Noteworthy"];
    else if ([generic isEqualToString:@"fantasy"]) candidates = @[@"Papyrus"];
    CTFontRef base = NULL;
    for (NSString *name in candidates ?: @[]) {
        CTFontRef try_ = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
        NSString *family = CFBridgingRelease(CTFontCopyFamilyName(try_));
        if ([family caseInsensitiveCompare:name] == NSOrderedSame) { base = try_; break; }
        CFRelease(try_);
    }
    if (!base) {
        CTFontRef system = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
        base = system ?: CTFontCreateWithName(CFSTR("Helvetica"), size, NULL);
    }
    CTFontSymbolicTraits traits = 0;
    if (weight >= 600) traits |= kCTFontTraitBold;
    if (italic) traits |= kCTFontTraitItalic;
    CTFontRef out = fontWithTraits(base, size, traits, weightAxisOf(weight));
    CFRelease(base);
    return out;
}

CTFontRef _Nullable SGCFontForFamilies(NSArray<NSString *> *families, CGFloat size, NSInteger weight, BOOL italic) {
    if (size <= 0) size = 12;
    for (NSString *raw in families) {
        NSString *family = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!family.length) continue;
        if ([family isEqualToString:@"system-ui"] || [family isEqualToString:@"-apple-system"] ||
            [family isEqualToString:@"sans-serif"] || [family isEqualToString:@"ui-sans-serif"]) {
            return genericFont(@"sans-serif", size, weight, italic);
        }
        if ([family isEqualToString:@"serif"] || [family isEqualToString:@"ui-serif"]) return genericFont(@"serif", size, weight, italic);
        if ([family isEqualToString:@"monospace"] || [family isEqualToString:@"ui-monospace"]) return genericFont(@"monospace", size, weight, italic);
        if ([family isEqualToString:@"cursive"]) return genericFont(@"cursive", size, weight, italic);
        if ([family isEqualToString:@"fantasy"]) return genericFont(@"fantasy", size, weight, italic);
        if ([family isEqualToString:@"math"] || [family isEqualToString:@"fangsong"]) continue;
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)family, size, NULL);
        NSString *have = CFBridgingRelease(CTFontCopyFamilyName(font));
        BOOL match = [have caseInsensitiveCompare:family] == NSOrderedSame;
        if (!match && SGFontCatalogHasFamily(family)) {
            // a catalog font registers under its family; the create above resolves it once that landed
            have = CFBridgingRelease(CTFontCopyFamilyName(CTFontCreateWithName((__bridge CFStringRef)family, size, NULL)));
            match = [have caseInsensitiveCompare:family] == NSOrderedSame;
        }
        if (match) {
            CTFontSymbolicTraits traits = 0;
            if (weight >= 600) traits |= kCTFontTraitBold;
            if (italic) traits |= kCTFontTraitItalic;
            CTFontRef out = fontWithTraits(font, size, traits, [have caseInsensitiveCompare:@"system"] == NSOrderedSame ? weightAxisOf(weight) : 0);
            CFRelease(font);
            return out;
        }
        CFRelease(font);
    }
    return genericFont(@"sans-serif", size, weight, italic);
}

#pragma mark - the context

@implementation SGCCtx
@end

id _Nullable SGCTakeCF(SGCStyle *style, CFTypeRef _Nullable ref) {
    if (!ref) return nil;
    if (!style.owned) style.owned = [NSMutableArray array];
    id object = CFBridgingRelease(ref);
    [style.owned addObject:object];
    return object;
}

CGColorRef _Nullable SGCStyleColor(SGCStyle *style, CGColorRef _Nullable color) {
    if (!color) return NULL;
    return (CGColorRef)CFBridgingRetain(SGCTakeCF(style, color));
}

CTFontRef _Nullable SGCStyleFont(SGCStyle *style, CTFontRef _Nullable font) {
    if (!font) return NULL;
    return (CTFontRef)CFBridgingRetain(SGCTakeCF(style, font));
}

#pragma mark - value helpers over a box's winners

static NSArray<SGCTok *> *valueOf(SGCBox *box, NSString *prop, NSDictionary *vars) {
    SGCDecl *decl = box.decls[prop];
    if (!decl) return nil;
    return SGCExpandVars(decl.value, vars);
}

static BOOL identIs(NSArray<SGCTok *> *tokens, NSString *what) {
    return tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:what];
}

#pragma mark - gradients

static SGCGradient *parseGradient(SGCTok *func, SGCLenCtx ctx, SGCStyle *owner);

static CGPoint parsePosition(NSArray<SGCTok *> *tokens, BOOL horizontal) {
    // keywords and percents to a fraction of the box; lengths land on the middle as the least
    // surprising answer, since none of the styles size a background in points
    CGFloat fraction = 0.5;
    BOOL found = NO;
    for (SGCTok *t in tokens) {
        if (t.type == SGCTokIdent) {
            NSString *name = t.text.lowercaseString;
            NSDictionary *map = horizontal ? @{@"left": @0, @"center": @0.5, @"right": @1}
                                            : @{@"top": @0, @"center": @0.5, @"bottom": @1};
            NSNumber *value = map[name];
            if (value) { fraction = value.doubleValue; found = YES; }
        } else if (t.type == SGCTokPercent) {
            fraction = t.number / 100.0;
            found = YES;
        }
    }
    return found ? CGPointMake(fraction, 0) : CGPointMake(NSNotFound, 0);
}

SGCGradient *SGCGradientParse(SGCTok *func, SGCLenCtx ctx, SGCStyle *owner) {
    return parseGradient(func, ctx, owner);
}

static SGCGradient *parseGradient(SGCTok *func, SGCLenCtx ctx, SGCStyle *owner) {
    NSString *name = func.text.lowercaseString;
    SGCGradient *g = [SGCGradient new];
    if ([name hasPrefix:@"repeating-"]) { g.repeating = YES; name = [name substringFromIndex:10]; }
    if ([name isEqualToString:@"linear-gradient"]) g.kind = 0;
    else if ([name isEqualToString:@"radial-gradient"]) g.kind = 1;
    else if ([name isEqualToString:@"conic-gradient"]) g.kind = 2;
    else return nil;

    NSMutableArray<NSArray<SGCTok *> *> *groups = [SGCSplitCommas(func.args) mutableCopy];
    if (!groups.count) return nil;

    // the first group may carry the direction: an angle, to-side words, or shape/at words
    NSArray<SGCTok *> *first = groups.firstObject;
    if (g.kind == 0 && first.count == 1 &&
        (first[0].type == SGCTokDimension || first[0].type == SGCTokNumber)) {
        double angle = first[0].number;
        NSString *unit = (first[0].type == SGCTokDimension ? first[0].unit.lowercaseString : @"deg");
        if ([unit isEqualToString:@"turn"]) angle *= 360;
        else if ([unit isEqualToString:@"rad"]) angle *= 180 / M_PI;
        else if ([unit isEqualToString:@"grad"]) angle *= 0.9;
        g.angle = angle;
        [groups removeObjectAtIndex:0];
    } else if (first.count && first[0].type == SGCTokIdent &&
               [first[0].text.lowercaseString isEqualToString:@"to"]) {
        double angle = 0;   // to top
        for (SGCTok *t in first) {
            NSString *word = t.text.lowercaseString;
            if ([word isEqualToString:@"right"]) angle = 90;
            else if ([word isEqualToString:@"bottom"]) angle = angle == 90 ? 135 : 180;
            else if ([word isEqualToString:@"left"]) angle = 270;
        }
        g.angle = angle;
        [groups removeObjectAtIndex:0];
    } else if (g.kind >= 1 && first.count && first[0].type == SGCTokIdent &&
               ![first[0].text.lowercaseString isEqualToString:@"at"] &&
               ![first[0].text.lowercaseString isEqualToString:@"from"]) {
        // circle/ellipse and size words, then possibly "at x y"
        CGFloat cx = 0.5, cy = 0.5;
        NSUInteger at = 0;
        while (at < first.count && !(first[at].type == SGCTokIdent &&
                                     [first[at].text.lowercaseString isEqualToString:@"at"])) at++;
        if (at < first.count) at++;
        BOOL verticalNext = NO;
        for (; at < first.count; at++) {
            SGCTok *t = first[at];
            NSString *word = t.type == SGCTokIdent ? t.text.lowercaseString : nil;
            if ([word isEqualToString:@"left"]) { cx = 0; continue; }
            if ([word isEqualToString:@"right"]) { cx = 1; continue; }
            if ([word isEqualToString:@"top"]) { cy = 0; continue; }
            if ([word isEqualToString:@"bottom"]) { cy = 1; continue; }
            if ([word isEqualToString:@"center"]) continue;
            if (t.type == SGCTokPercent) {
                if (verticalNext) cy = t.number / 100.0;
                else { cx = t.number / 100.0; verticalNext = YES; }
            }
        }
        g.center = CGPointMake(cx, cy);
        [groups removeObjectAtIndex:0];
    } else if (first.count >= 2 && first[0].type == SGCTokIdent &&
               [first[0].text.lowercaseString isEqualToString:@"from"]) {
        g.from = first[1].number;
        [groups removeObjectAtIndex:0];
    }
    if (g.kind == 0 && g.angle == 0 && (groups.count == [SGCSplitCommas(func.args) count]))
        g.angle = 180;   // no direction given: to bottom

    // stops: colours with up to two positions each, kept as fractions or points for the painter
    NSMutableArray *colors = [NSMutableArray array];
    NSMutableArray<NSNumber *> *stopsPt = [NSMutableArray array];
    NSMutableArray<NSNumber *> *stopsFraction = [NSMutableArray array];
    for (NSArray<SGCTok *> *group in groups) {
        NSMutableArray<SGCTok *> *colorTokens = [NSMutableArray array];
        NSMutableArray<SGCTok *> *positions = [NSMutableArray array];
        for (SGCTok *t in group) {
            if (t.type == SGCTokPercent || t.type == SGCTokDimension) [positions addObject:t];
            else if (t.type == SGCTokDelim) continue;
            else [colorTokens addObject:t];
        }
        CGColorRef color = SGCColor(colorTokens, NULL);
        if (!color) continue;
        SGCTakeCF(owner, color);   // the style keeps it alive; the gradient only points at it
        [colors addObject:[NSValue valueWithPointer:color]];
        CGFloat pt = NAN, fraction = NAN;
        if (positions.count) {
            SGCTok *p = positions[0];
            if (p.type == SGCTokPercent) fraction = p.number / 100.0;
            else pt = SGLengthValue(p.number, p.unit, ctx);
        }
        [stopsPt addObject:@(pt)];
        [stopsFraction addObject:@(fraction)];
    }
    if (!colors.count) return nil;
    g.colors = colors;
    g.stopsPt = stopsPt;
    g.stopsFraction = stopsFraction;
    return g;
}

#pragma mark - shorthand forms

// 1 to 4 sides, css order: top right bottom left, pairs mirrored. The tokenizer dropped the
// spaces, so each dimension token is one value; calc and friends arrive as one function token.
static void sides4(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base,
                   CGFloat *top, CGFloat *right, CGFloat *bottom, CGFloat *left) {
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    for (SGCTok *t in tokens) {
        CGFloat value = 0;
        if (SGCLenOrPercent(@[t], ctx, base, &value)) [values addObject:@(value)];
    }
    if (!values.count) return;
    *top = values[0].doubleValue;
    *right = values.count > 1 ? values[1].doubleValue : values[0].doubleValue;
    *bottom = values.count > 2 ? values[2].doubleValue : values[0].doubleValue;
    *left = values.count > 3 ? values[3].doubleValue : (values.count > 1 ? values[1].doubleValue : values[0].doubleValue);
}

#pragma mark - computed style

static void computeBackground(SGCStyle *s, SGCBox *box, NSDictionary *vars, SGCLenCtx ctx, CGColorRef inheritedColor) {
    NSMutableArray<SGCBGLayer *> *layers = [NSMutableArray array];

    void (^parseLayer)(NSArray<SGCTok *> *, BOOL) = ^(NSArray<SGCTok *> *tokens, BOOL allowColor) {
        SGCBGLayer *layer = [SGCBGLayer new];
        NSMutableArray<SGCTok *> *positionTokens = [NSMutableArray array];
        NSMutableArray<SGCTok *> *sizeTokens = [NSMutableArray array];
        BOOL sawSlash = NO;
        for (SGCTok *t in tokens) {
            if (t.type == SGCTokFunc) {
                SGCGradient *gradient = SGCGradientParse(t, ctx, s);
                if (gradient) layer.gradient = gradient;
                continue;
            }
            if (t.type == SGCTokDelim && [t.text isEqualToString:@"/"]) { sawSlash = YES; continue; }
            if (t.type == SGCTokIdent) {
                NSString *word = t.text.lowercaseString;
                if ([word isEqualToString:@"none"]) continue;
                if ([word isEqualToString:@"cover"] && sawSlash) { layer.sizeKind = 1; continue; }
                if ([word isEqualToString:@"contain"] && sawSlash) { layer.sizeKind = 2; continue; }
                if ([word isEqualToString:@"cover"] && !layer.gradient && !layer.coverImage && positionTokens.count == 0) {
                    // the cover marker the painter resolves to the artwork
                    layer.coverImage = YES;
                    continue;
                }
                if ([word isEqualToString:@"no-repeat"]) { layer.repeatNone = YES; continue; }
                if ([word isEqualToString:@"repeat"] || [word isEqualToString:@"repeat-x"] || [word isEqualToString:@"repeat-y"]) continue;
                if ([word isEqualToString:@"center"] || [word isEqualToString:@"left"] || [word isEqualToString:@"right"] ||
                    [word isEqualToString:@"top"] || [word isEqualToString:@"bottom"]) {
                    [positionTokens addObject:t];
                    continue;
                }
                if (allowColor && !layer.gradient && !layer.coverImage) {
                    CGColorRef color = SGCColorFromString(word, inheritedColor);
                    if (color) {
                        s.backgroundColor = SGCStyleColor(s, color);
                        continue;
                    }
                }
                continue;
            }
            if (t.type == SGCTokHash) {
                CGColorRef color = SGCColorFromString([@"#" stringByAppendingString:t.text], inheritedColor);
                if (color && allowColor) {
                    s.backgroundColor = SGCStyleColor(s, color);
                }
                continue;
            }
            if (t.type == SGCTokPercent || t.type == SGCTokDimension) {
                [sawSlash ? sizeTokens : positionTokens addObject:t];
                continue;
            }
        }
        if (positionTokens.count) {
            CGPoint horizontal = parsePosition(positionTokens, YES);
            CGPoint vertical = parsePosition(positionTokens, NO);
            layer.position = CGPointMake(horizontal.x == NSNotFound ? 0.5 : horizontal.x,
                                         vertical.x == NSNotFound ? 0.5 : vertical.x);
        } else {
            layer.position = CGPointMake(0.5, 0.5);
        }
        if (sizeTokens.count) {
            CGFloat w = 0, h = 0;
            if (SGCLenOrPercent(sizeTokens, ctx, ctx.cardW, &w) && w > 0) {
                layer.size = CGSizeMake(w, h > 0 ? h : w);
                layer.sizeKind = 0;
            }
        }
        if (layer.gradient || layer.coverImage) [layers addObject:layer];
    };

    SGCDecl *background = box.decls[@"background"];
    if (background) {
        NSArray<SGCTok *> *expanded = SGCExpandVars(background.value, vars) ?: @[];
        // layers split on top-level commas; the final layer may carry the colour
        NSArray<NSArray<SGCTok *> *> *groups = SGCSplitCommas(expanded);
        for (NSUInteger i = 0; i < groups.count; i++)
            parseLayer(groups[i], i == groups.count - 1);
    }
    SGCDecl *image = box.decls[@"background-image"];
    if (image) {
        layers = [NSMutableArray array];
        for (NSArray<SGCTok *> *group in SGCSplitCommas(SGCExpandVars(image.value, vars) ?: @[]))
            parseLayer(group, NO);
    }
    if (box.decls[@"background-color"]) {
        CGColorRef color = SGCColor(SGCExpandVars(box.decls[@"background-color"].value, vars) ?: @[], inheritedColor);
        if (color) s.backgroundColor = SGCStyleColor(s, color);
    }
    if (box.decls[@"background-position"] && layers.count) {
        CGPoint horizontal = parsePosition(SGCExpandVars(box.decls[@"background-position"].value, vars) ?: @[], YES);
        CGPoint vertical = parsePosition(SGCExpandVars(box.decls[@"background-position"].value, vars) ?: @[], NO);
        layers[0].position = CGPointMake(horizontal.x == NSNotFound ? 0.5 : horizontal.x,
                                         vertical.x == NSNotFound ? 0.5 : vertical.x);
    }
    if ([box.decls[@"background-size"] value] && layers.count) {
        SGCBGLayer *layer = layers[0];
        for (SGCTok *t in SGCExpandVars(box.decls[@"background-size"].value, vars) ?: @[]) {
            if (t.type == SGCTokIdent && [t.text.lowercaseString isEqualToString:@"cover"]) layer.sizeKind = 1;
            if (t.type == SGCTokIdent && [t.text.lowercaseString isEqualToString:@"contain"]) layer.sizeKind = 2;
        }
    }
    s.bgLayers = layers;
}

static uint8_t blendNamed(NSString *name) {
    if ([name isEqualToString:@"multiply"]) return kCGBlendModeMultiply;
    if ([name isEqualToString:@"screen"]) return kCGBlendModeScreen;
    if ([name isEqualToString:@"overlay"]) return kCGBlendModeOverlay;
    if ([name isEqualToString:@"darken"]) return kCGBlendModeDarken;
    if ([name isEqualToString:@"lighten"]) return kCGBlendModeLighten;
    if ([name isEqualToString:@"color-dodge"]) return kCGBlendModeColorDodge;
    if ([name isEqualToString:@"color-burn"]) return kCGBlendModeColorBurn;
    if ([name isEqualToString:@"soft-light"]) return kCGBlendModeSoftLight;
    if ([name isEqualToString:@"hard-light"]) return kCGBlendModeHardLight;
    if ([name isEqualToString:@"difference"]) return kCGBlendModeDifference;
    if ([name isEqualToString:@"exclusion"]) return kCGBlendModeExclusion;
    if ([name isEqualToString:@"hue"]) return kCGBlendModeHue;
    if ([name isEqualToString:@"saturation"]) return kCGBlendModeSaturation;
    if ([name isEqualToString:@"color"]) return kCGBlendModeColor;
    if ([name isEqualToString:@"luminosity"]) return kCGBlendModeLuminosity;
    return kCGBlendModeNormal;
}

static void computeText(SGCStyle *s, SGCBox *box, NSDictionary *vars, SGCLenCtx ctx, SGCStyle *parent) {
    CGFloat fontSize = parent ? parent.fontSize : 16;
    NSInteger weight = 400;
    BOOL italic = NO;
    NSArray<NSString *> *families = @[@"system-ui"];

    SGCDecl *font = box.decls[@"font"];
    if (font) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(font.value, vars) ?: @[];
        NSMutableArray<SGCTok *> *rest = [tokens mutableCopy];
        // style, then weight, then size with an optional /line-height, then the families
        while (rest.count && rest[0].type == SGCTokIdent) {
            NSString *word = rest[0].text.lowercaseString;
            if ([word isEqualToString:@"italic"] || [word isEqualToString:@"oblique"]) { italic = YES; [rest removeObjectAtIndex:0]; continue; }
            if ([word isEqualToString:@"small-caps"] || [word isEqualToString:@"normal"]) { [rest removeObjectAtIndex:0]; continue; }
            break;
        }
        if (rest.count && rest[0].type == SGCTokNumber && rest[0].number >= 100 && rest[0].number <= 1000) {
            weight = (NSInteger)rest[0].number;
            [rest removeObjectAtIndex:0];
        } else if (rest.count && rest[0].type == SGCTokIdent) {
            NSString *word = rest[0].text.lowercaseString;
            if ([word isEqualToString:@"bold"]) { weight = 700; [rest removeObjectAtIndex:0]; }
            else if ([word isEqualToString:@"lighter"]) { weight = 300; [rest removeObjectAtIndex:0]; }
            else if ([word isEqualToString:@"bolder"]) { weight = 800; [rest removeObjectAtIndex:0]; }
        }
        if (rest.count) {
            CGFloat size = 0;
            NSArray<SGCTok *> *sizeTokens = @[rest[0]];
            [rest removeObjectAtIndex:0];
            if (SGCLenOrPercent(SGCStrip(sizeTokens), ctx, parent ? parent.fontSize : 16, &size) && size > 0) fontSize = size;
            if (rest.count && rest[0].type == SGCTokDelim && [rest[0].text isEqualToString:@"/"]) {
                [rest removeObjectAtIndex:0];
                if (rest.count) {
                    SGCTok *lh = rest[0];
                    [rest removeObjectAtIndex:0];
                    if (lh.type == SGCTokNumber) s.lineHeight = fontSize * lh.number;
                    else if (lh.type == SGCTokDimension || lh.type == SGCTokPercent) {
                        CGFloat value = 0;
                        if (SGCLenOrPercent(@[lh], ctx, fontSize, &value)) s.lineHeight = value;
                    }
                }
            }
        }
        // what is left is the family list
        if (rest.count) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSArray<SGCTok *> *group in SGCSplitCommas(rest)) {
                NSMutableArray<NSString *> *words = [NSMutableArray array];
                for (SGCTok *t in group) {
                    if (t.type == SGCTokString) [words addObject:t.text];
                    else if (t.type == SGCTokIdent && ![t.text.lowercaseString isEqualToString:@"important"]) [words addObject:t.text];
                }
                NSString *name = [words componentsJoinedByString:@" "];
                if (name.length) [names addObject:name];
            }
            if (names.count) families = names;
        }
    }
    if (box.decls[@"font-size"]) {
        CGFloat size = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"font-size"].value, vars) ?: @[], ctx, parent ? parent.fontSize : 16, &size) && size > 0)
            fontSize = size;
    }
    if (box.decls[@"font-weight"]) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(box.decls[@"font-weight"].value, vars) ?: @[];
        if (tokens.count == 1) {
            if (tokens[0].type == SGCTokNumber) weight = (NSInteger)tokens[0].number;
            else {
                NSString *word = tokens[0].text.lowercaseString;
                if ([word isEqualToString:@"bold"]) weight = 700;
                else if ([word isEqualToString:@"lighter"]) weight = 300;
                else if ([word isEqualToString:@"bolder"]) weight = 800;
            }
        }
    }
    if (box.decls[@"font-style"]) italic = identIs(SGCExpandVars(box.decls[@"font-style"].value, vars) ?: @[], @"italic") ||
                                          identIs(SGCExpandVars(box.decls[@"font-style"].value, vars) ?: @[], @"oblique");
    if (box.decls[@"font-family"]) {
        NSMutableArray<NSString *> *names = [NSMutableArray array];
        for (NSArray<SGCTok *> *group in SGCSplitCommas(SGCExpandVars(box.decls[@"font-family"].value, vars) ?: @[])) {
            NSMutableArray<NSString *> *words = [NSMutableArray array];
            for (SGCTok *t in group) {
                if (t.type == SGCTokString) [words addObject:t.text];
                else if (t.type == SGCTokIdent) [words addObject:t.text];
            }
            NSString *name = [words componentsJoinedByString:@" "];
            if (name.length) [names addObject:name];
        }
        if (names.count) families = names;
    }

    ctx.em = fontSize;
    s.fontSize = fontSize;
    if (box.decls[@"font"] || box.decls[@"font-family"] || box.decls[@"font-weight"] || box.decls[@"font-style"]) {
        s.font = SGCStyleFont(s, SGCFontForFamilies(families, fontSize, weight, italic));
    } else if (parent && parent.font) {
        if (fontSize == parent.fontSize) {
            s.font = parent.font;
            CFRetain(s.font);
        } else {
            s.font = SGCStyleFont(s, CTFontCreateCopyWithAttributes(parent.font, fontSize, NULL, NULL));
        }
    }

    if (box.decls[@"line-height"]) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(box.decls[@"line-height"].value, vars) ?: @[];
        if (tokens.count == 1 && tokens[0].type == SGCTokNumber) s.lineHeight = fontSize * tokens[0].number;
        else {
            CGFloat value = 0;
            if (SGCLenOrPercent(tokens, ctx, fontSize, &value)) s.lineHeight = value;
        }
    }
    s.color = NULL;
    if (box.decls[@"color"]) {
        CGColorRef color = SGCColor(SGCExpandVars(box.decls[@"color"].value, vars) ?: @[], parent ? parent.color : NULL);
        if (color) s.color = SGCStyleColor(s, color);
    } else if (parent) {
        s.color = parent.color;
        CGColorRetain(s.color);
    }
    if (!s.color) s.color = SGCStyleColor(s, CGColorCreateGenericRGB(1, 1, 1, 1));

    if (box.decls[@"letter-spacing"]) {
        CGFloat value = 0;
        NSArray<SGCTok *> *tokens = SGCExpandVars(box.decls[@"letter-spacing"].value, vars) ?: @[];
        if (SGCLenOrPercent(tokens, ctx, fontSize, &value)) s.letterSpacing = value;
        else if (identIs(tokens, @"normal")) s.letterSpacing = 0;
    }
    if (box.decls[@"word-spacing"]) {
        CGFloat value = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"word-spacing"].value, vars) ?: @[], ctx, fontSize, &value)) s.wordSpacing = value;
    }
    if (box.decls[@"text-indent"]) {
        CGFloat value = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"text-indent"].value, vars) ?: @[], ctx, fontSize, &value)) s.textIndent = value;
    }
    if (box.decls[@"text-align"]) {
        NSString *word = SGCExpandVars(box.decls[@"text-align"].value, vars).firstObject.text.lowercaseString;
        if ([word isEqualToString:@"center"]) s.textAlign = SGCTextCenter;
        else if ([word isEqualToString:@"right"] || [word isEqualToString:@"end"]) s.textAlign = SGCTextRight;
    }
    if (box.decls[@"text-transform"]) {
        NSString *word = SGCExpandVars(box.decls[@"text-transform"].value, vars).firstObject.text.lowercaseString;
        if ([word isEqualToString:@"uppercase"]) s.textForm = SGCTextUpper;
        else if ([word isEqualToString:@"lowercase"]) s.textForm = SGCTextLower;
    }
    if (box.decls[@"white-space"]) s.nowrap = identIs(SGCExpandVars(box.decls[@"white-space"].value, vars) ?: @[], @"nowrap");
    if (box.decls[@"text-wrap"]) s.balance = identIs(SGCExpandVars(box.decls[@"text-wrap"].value, vars) ?: @[], @"balance");
    if (box.decls[@"overflow-wrap"] || box.decls[@"word-wrap"]) {
        NSString *word = (box.decls[@"overflow-wrap"] ?: box.decls[@"word-wrap"]).value.firstObject.text.lowercaseString;
        s.breakWords = [word isEqualToString:@"break-word"] || [word isEqualToString:@"anywhere"];
    }
    if (box.decls[@"text-decoration"]) {
        for (SGCTok *t in SGCExpandVars(box.decls[@"text-decoration"].value, vars) ?: @[])
            if (t.type == SGCTokIdent && [t.text.lowercaseString isEqualToString:@"underline"]) s.textDecoration = YES;
    }

    // text-shadow: layers of dx dy blur? colour?
    SGCDecl *ts = box.decls[@"text-shadow"];
    if (ts && !identIs(ts.value, @"none")) {
        NSMutableArray<SGCTextShadow *> *shadows = [NSMutableArray array];
        for (NSArray<SGCTok *> *group in SGCSplitCommas(SGCExpandVars(ts.value, vars) ?: @[])) {
            NSMutableArray<SGCTok *> *numbers = [NSMutableArray array], *colorTokens = [NSMutableArray array];
            for (SGCTok *t in group) {
                if (t.type == SGCTokNumber || t.type == SGCTokDimension || t.type == SGCTokPercent) [numbers addObject:t];
                else [colorTokens addObject:t];
            }
            if (numbers.count < 2) continue;
            SGCTextShadow *shadow = [SGCTextShadow new];
            shadow.dx = lengthOfToken(numbers[0], ctx);
            shadow.dy = lengthOfToken(numbers[1], ctx);
            shadow.blur = numbers.count > 2 ? lengthOfToken(numbers[2], ctx) : 0;
            CGColorRef color = SGCColor(colorTokens, s.color);
            shadow.color = color ?: CGColorRetain(s.color);
            SGCTakeCF(s, shadow.color);
            [shadows addObject:shadow];
        }
        s.textShadows = shadows;
    } else if (parent && parent.textShadows.count) {
        // text-shadow inherits; the shadow's colour was fixed at the parent, the offsets travel
        s.textShadows = parent.textShadows;
    }
}

static void computeBox(SGCStyle *s, SGCBox *box, NSDictionary *vars, SGCLenCtx ctx, SGCStyle *parent) {
    CGFloat percentW = ctx.cardW, percentH = ctx.cardH;   // percents read the card, the one definite container

    if (box.decls[@"display"]) {
        NSString *word = box.decls[@"display"].value.firstObject.text.lowercaseString;
        if ([word isEqualToString:@"none"]) s.display = SGCDisplayNone;
        else if ([word isEqualToString:@"flex"]) s.display = SGCDisplayFlex;
        else if ([word isEqualToString:@"block"]) s.display = SGCDisplayBlock;
        else if ([word isEqualToString:@"inline-block"]) s.display = SGCDisplayInlineBlock;
        else if ([word isEqualToString:@"inline"]) s.display = SGCDisplayInline;
    }
    if (box.decls[@"position"]) {
        NSString *word = box.decls[@"position"].value.firstObject.text.lowercaseString;
        if ([word isEqualToString:@"absolute"]) s.position = 2;
        else if ([word isEqualToString:@"relative"]) s.position = 1;
    }

    CGFloat (^lenOf)(NSString *, CGFloat, BOOL *) = ^CGFloat(NSString *prop, CGFloat base, BOOL *ok) {
        CGFloat value = 0;
        *ok = NO;
        SGCDecl *decl = box.decls[prop];
        if (!decl) return 0;
        NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
        if (tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:@"auto"]) return 0;
        *ok = SGCLenOrPercent(tokens, ctx, base, &value);
        return value;
    };

    // padding, then margins with their auto form
    {
        SGCDecl *decl = box.decls[@"padding"];
        if (decl) {
            CGFloat t = 0, r = 0, b = 0, l = 0;
            sides4(SGCExpandVars(decl.value, vars) ?: @[], ctx, percentW, &t, &r, &b, &l);
            s.padding = UIEdgeInsetsMake(t, l, b, r);
        }
        for (NSString *side in @[@"top", @"right", @"bottom", @"left"]) {
            BOOL ok = NO;
            CGFloat value = lenOf([NSString stringWithFormat:@"padding-%@", side], percentW, &ok);
            if (!ok) continue;
            if ([side isEqualToString:@"top"]) s.padding.top = value;
            if ([side isEqualToString:@"bottom"]) s.padding.bottom = value;
            if ([side isEqualToString:@"left"]) s.padding.left = value;
            if ([side isEqualToString:@"right"]) s.padding.right = value;
        }
    }
    {
        SGCDecl *decl = box.decls[@"margin"];
        if (decl) {
            NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
            if (!(tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:@"auto"])) {
                CGFloat t = 0, r = 0, b = 0, l = 0;
                sides4(tokens, ctx, percentW, &t, &r, &b, &l);
                s.margin = UIEdgeInsetsMake(t, l, b, r);
            } else {
                s.marginLeftAuto = s.marginRightAuto = YES;
            }
        }
        for (NSString *side in @[@"top", @"right", @"bottom", @"left"]) {
            SGCDecl *decl = box.decls[[NSString stringWithFormat:@"margin-%@", side]];
            if (!decl) continue;
            NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
            BOOL auto_ = tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:@"auto"];
            CGFloat value = 0;
            if (auto_) {
                if ([side isEqualToString:@"left"]) { s.marginLeftAuto = YES; s.margin.left = 0; }
                if ([side isEqualToString:@"right"]) { s.marginRightAuto = YES; s.margin.right = 0; }
            } else if (SGCLenOrPercent(tokens, ctx, percentW, &value)) {
                if ([side isEqualToString:@"top"]) s.margin.top = value;
                if ([side isEqualToString:@"bottom"]) s.margin.bottom = value;
                if ([side isEqualToString:@"left"]) s.margin.left = value;
                if ([side isEqualToString:@"right"]) s.margin.right = value;
            }
        }
    }

    // insets: the shorthand plus the four longhands; auto clears what an outer sheet set
    {
        SGCDecl *decl = box.decls[@"inset"];
        if (decl) {
            NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
            BOOL allAuto = tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:@"auto"];
            if (allAuto) {
                s.hasLeft = s.hasTop = s.hasRight = s.hasBottom = NO;
            } else {
                CGFloat t = 0, r = 0, b = 0, l = 0;
                sides4(tokens, ctx, percentW, &t, &r, &b, &l);
                s.hasLeft = s.hasTop = s.hasRight = s.hasBottom = YES;
                s.top = t; s.right = r; s.bottom = b; s.left = l;
            }
        }
        for (NSString *side in @[@"top", @"right", @"bottom", @"left"]) {
            SGCDecl *decl = box.decls[side];
            if (!decl) continue;
            NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
            if (tokens.count == 1 && tokens[0].type == SGCTokIdent && [tokens[0].text.lowercaseString isEqualToString:@"auto"]) {
                if ([side isEqualToString:@"top"]) s.hasTop = NO;
                if ([side isEqualToString:@"right"]) s.hasRight = NO;
                if ([side isEqualToString:@"bottom"]) s.hasBottom = NO;
                if ([side isEqualToString:@"left"]) s.hasLeft = NO;
                continue;
            }
            CGFloat value = 0;
            if (!SGCLenOrPercent(tokens, ctx, percentW, &value)) continue;
            if ([side isEqualToString:@"top"]) { s.top = value; s.hasTop = YES; }
            if ([side isEqualToString:@"right"]) { s.right = value; s.hasRight = YES; }
            if ([side isEqualToString:@"bottom"]) { s.bottom = value; s.hasBottom = YES; }
            if ([side isEqualToString:@"left"]) { s.left = value; s.hasLeft = YES; }
        }
    }

    auto setSize = ^(NSString *prop, CGFloat *out, BOOL *set, BOOL vertical) {
        SGCDecl *decl = box.decls[prop];
        if (!decl) return;
        NSArray<SGCTok *> *tokens = SGCExpandVars(decl.value, vars) ?: @[];
        if (tokens.count == 1 && tokens[0].type == SGCTokIdent) return;   // auto, max-content and friends stay unset
        CGFloat value = 0;
        if (SGCLenOrPercent(tokens, ctx, vertical ? percentH : percentW, &value)) {
            *out = value;
            *set = YES;
        }
    };
    setSize(@"width", &s.width, &s.widthSet, NO);
    setSize(@"height", &s.height, &s.heightSet, YES);
    setSize(@"max-width", &s.maxWidth, &s.maxWSet, NO);
    setSize(@"max-height", &s.maxHeight, &s.maxHSet, YES);
    setSize(@"min-width", &s.minWidth, &s.minWSet, NO);
    setSize(@"min-height", &s.minHeight, &s.minHSet, YES);

    // flex
    SGCDecl *flex = box.decls[@"flex"];
    if (flex && !identIs(flex.value, @"none")) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(flex.value, vars) ?: @[];
        NSMutableArray<SGCTok *> *numbers = [NSMutableArray array];
        NSMutableArray<SGCTok *> *rest = [NSMutableArray array];
        for (SGCTok *t in tokens) {
            if (t.type == SGCTokNumber && numbers.count < 2 && rest.count == 0) [numbers addObject:t];
            else [rest addObject:t];
        }
        if (numbers.count >= 1) s.grow = numbers[0].number;
        if (numbers.count >= 2) s.shrink = numbers[1].number;
        else if (numbers.count == 1) { s.shrink = 1; s.basisSet = YES; s.basis = 0; }   // flex: 1 means 1 1 0%
        if (rest.count) {
            CGFloat value = 0;
            if (SGCLenOrPercent(rest, ctx, percentW, &value)) { s.basisSet = YES; s.basis = value; }
        }
        if (numbers.count >= 2 && !rest.count) { s.basisSet = NO; }   // flex: 1 1 auto
    }
    if (box.decls[@"flex-grow"]) {
        s.grow = box.decls[@"flex-grow"].value.firstObject.number;
    }
    if (box.decls[@"flex-shrink"]) {
        s.shrink = box.decls[@"flex-shrink"].value.firstObject.number;
        s.shrinkNone = s.shrink == 0;
    }
    if (box.decls[@"flex-basis"]) {
        CGFloat value = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"flex-basis"].value, vars) ?: @[], ctx, percentW, &value)) {
            s.basisSet = YES;
            s.basis = value;
        }
    }
    if (box.decls[@"order"]) s.order = (NSInteger)box.decls[@"order"].value.firstObject.number;
    // gap: row-gap then column-gap, space separated, one value meaning both
    if (box.decls[@"gap"]) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(box.decls[@"gap"].value, vars) ?: @[];
        NSMutableArray<NSArray<SGCTok *> *> *groups = [NSMutableArray array];
        NSMutableArray<SGCTok *> *current = [NSMutableArray array];
        for (SGCTok *t in tokens) {
            if (t.type == SGCTokDimension || t.type == SGCTokNumber || t.type == SGCTokPercent || t.type == SGCTokFunc) {
                [current addObject:t];
            } else if (current.count) {
                [groups addObject:current];
                current = [NSMutableArray array];
            }
        }
        if (current.count) [groups addObject:current];
        CGFloat row = 0, column = 0;
        if (groups.count && SGCLenOrPercent(groups[0], ctx, percentW, &row)) {
            column = groups.count > 1 && SGCLenOrPercent(groups[1], ctx, percentW, &column) ? column : row;
            s.gapRow = row;
            s.gapColumn = column;
        }
    }
    if (box.decls[@"row-gap"]) {
        CGFloat value = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"row-gap"].value, vars) ?: @[], ctx, percentW, &value)) s.gapRow = value;
    }
    if (box.decls[@"column-gap"]) {
        CGFloat value = 0;
        if (SGCLenOrPercent(SGCExpandVars(box.decls[@"column-gap"].value, vars) ?: @[], ctx, percentW, &value)) s.gapColumn = value;
    }
    if (box.decls[@"flex-direction"]) {
        NSString *word = box.decls[@"flex-direction"].value.firstObject.text.lowercaseString;
        s.direction = [word isEqualToString:@"column"] ? SGCDirColumn : SGCDirRow;
    }
    if (box.decls[@"justify-content"]) {
        NSString *word = box.decls[@"justify-content"].value.firstObject.text.lowercaseString;
        if ([word isEqualToString:@"center"]) s.justify = SGCPackCenter;
        else if ([word isEqualToString:@"flex-end"] || [word isEqualToString:@"end"]) s.justify = SGCPackEnd;
        else if ([word isEqualToString:@"space-between"]) s.justify = SGCPackBetween;
        else if ([word isEqualToString:@"space-around"] || [word isEqualToString:@"space-evenly"]) s.justify = SGCPackAround;
    }
    auto alignOf = ^(NSArray<SGCTok *> *tokens, SGCAlign *out) {
        if (tokens.count != 1) return;
        NSString *word = tokens[0].text.lowercaseString;
        if ([word isEqualToString:@"flex-start"] || [word isEqualToString:@"start"]) *out = SGCAlignStart;
        else if ([word isEqualToString:@"center"]) *out = SGCAlignCenter;
        else if ([word isEqualToString:@"flex-end"] || [word isEqualToString:@"end"]) *out = SGCAlignEnd;
        else if ([word isEqualToString:@"stretch"] || [word isEqualToString:@"normal"]) *out = SGCAlignStretch;
    };
    if (box.decls[@"align-items"]) alignOf(SGCExpandVars(box.decls[@"align-items"].value, vars) ?: @[], &s.align);
    if (box.decls[@"align-self"]) {
        s.selfAlignSet = YES;
        s.selfAlign = s.align;
        alignOf(SGCExpandVars(box.decls[@"align-self"].value, vars) ?: @[], &s.selfAlign);
    }
    if (box.decls[@"flex-wrap"]) s.wrap = identIs(SGCExpandVars(box.decls[@"flex-wrap"].value, vars) ?: @[], @"wrap");

    if (box.decls[@"overflow"]) {
        NSString *word = box.decls[@"overflow"].value.firstObject.text.lowercaseString;
        s.overflowHidden = [word isEqualToString:@"hidden"] || [word isEqualToString:@"clip"];
    }
    if (box.decls[@"visibility"]) s.hidden = identIs(SGCExpandVars(box.decls[@"visibility"].value, vars) ?: @[], @"hidden");
    if (box.decls[@"opacity"]) {
        double value = 0;
        if (SGCNumber(SGCExpandVars(box.decls[@"opacity"].value, vars) ?: @[], ctx, &value)) s.opacity = value;
    }
    if (box.decls[@"z-index"]) {
        double value = 0;
        if (SGCNumber(SGCExpandVars(box.decls[@"z-index"].value, vars) ?: @[], ctx, &value)) s.z = (NSInteger)value;
    }
}

// One token that carries a length: a dimension through the unit map, a number as points.
static CGFloat lengthOfToken(SGCTok *t, SGCLenCtx ctx) {
    if (t.type == SGCTokNumber) return t.number;
    if (t.type == SGCTokDimension) return SGLengthValue(t.number, t.unit, ctx);
    if (t.type == SGCTokPercent) return t.number / 100.0 * ctx.cardW;
    return 0;
}

static void computePaint(SGCStyle *s, SGCBox *box, NSDictionary *vars, SGCLenCtx ctx, SGCStyle *parent) {
    computeBackground(s, box, vars, ctx, parent ? parent.color : NULL);

    // border-radius: 1 to 4 corners, space separated; a percent corner stays zero here and the
    // painter re-reads it against the box, so 50% is a circle on a square of any size
    SGCDecl *radius = box.decls[@"border-radius"];
    if (radius) {
        NSMutableArray<SGCTok *> *corners = [NSMutableArray array];
        for (SGCTok *t in SGCExpandVars(radius.value, vars) ?: @[]) {
            if (t.type == SGCTokPercent || t.type == SGCTokDimension || t.type == SGCTokNumber) [corners addObject:t];
        }
        if (corners.count >= 1 && corners.count <= 4) {
            CGFloat values[4] = {0, 0, 0, 0};
            for (NSUInteger i = 0; i < 4; i++) {
                SGCTok *t = corners[MIN(i, corners.count - 1)];
                if (t.type == SGCTokPercent) {
                    CGFloat fractions[4] = {0, 0, 0, 0};
                    for (NSUInteger k = 0; k < 4; k++) {
                        SGCTok *corner = corners[MIN(k, corners.count - 1)];
                        if (corner.type == SGCTokPercent) fractions[k] = corner.number / 100.0;
                    }
                    s.hasPercentRadius = YES;
                    s.radiusTL = fractions[0];
                    s.radiusTR = corners.count > 1 ? fractions[1] : fractions[0];
                    s.radiusBR = corners.count > 2 ? fractions[2] : fractions[0];
                    s.radiusBL = corners.count > 3 ? fractions[3] : (corners.count > 1 ? fractions[1] : fractions[0]);
                    return;
                }
                CGFloat value = 0;
                if (SGCLenOrPercent(@[t], ctx, ctx.cardW, &value)) values[i] = value;
            }
            s.radiusTL = values[0];
            s.radiusTR = corners.count > 1 ? values[1] : values[0];
            s.radiusBR = corners.count > 2 ? values[2] : values[0];
            s.radiusBL = corners.count > 3 ? values[3] : (corners.count > 1 ? values[1] : values[0]);
        }
    }

    // borders: the shorthand resets, the sides refine; width style colour in any order
    auto parseBorder = ^(NSArray<SGCTok *> *tokens, CGFloat *width, char *style, BOOL *hasColor) {
        NSMutableArray<SGCTok *> *colorTokens = [NSMutableArray array];
        *style = 's';
        *width = 0;
        for (SGCTok *t in tokens) {
            if (t.type == SGCTokDimension || t.type == SGCTokNumber) *width = lengthOfToken(t, ctx);
            else if (t.type == SGCTokIdent) {
                NSString *word = t.text.lowercaseString;
                if ([word isEqualToString:@"dashed"] || [word isEqualToString:@"dotted"]) *style = 'd';
                else if ([word isEqualToString:@"solid"]) *style = 's';
                else if ([word isEqualToString:@"none"] || [word isEqualToString:@"hidden"]) *style = 0;
                else [colorTokens addObject:t];
            } else if (t.type == SGCTokHash || t.type == SGCTokFunc || t.type == SGCTokString) {
                [colorTokens addObject:t];
            }
        }
        if (colorTokens.count) {
            CGColorRef color = SGCColor(colorTokens, s.color);
            if (color) {
                s.borderColor = SGCStyleColor(s, color);
                *hasColor = YES;
            }
        }
    };
    if (box.decls[@"border"]) {
        CGFloat w; char st; BOOL hasColor = NO;
        parseBorder(SGCExpandVars(box.decls[@"border"].value, vars) ?: @[], &w, &st, &hasColor);
        s.borderTop = s.borderRight = s.borderBottom = s.borderLeft = w;
        s.borderStyle = st;
    }
    auto sideBorder = ^(NSString *name, CGFloat *out) {
        SGCDecl *decl = box.decls[name];
        if (!decl) return;
        CGFloat w; char st; BOOL hasColor = NO;
        char old = s.borderStyle;
        CGColorRef oldColor = s.borderColor;
        parseBorder(SGCExpandVars(decl.value, vars) ?: @[], &w, &st, &hasColor);
        if (!hasColor) s.borderColor = oldColor;
        *out = st ? w : 0;
        if (st) s.borderStyle = st; else s.borderStyle = old;
    };
    sideBorder(@"border-top", &s.borderTop);
    sideBorder(@"border-right", &s.borderRight);
    sideBorder(@"border-bottom", &s.borderBottom);
    sideBorder(@"border-left", &s.borderLeft);

    // box-shadow
    SGCDecl *bs = box.decls[@"box-shadow"];
    if (bs && !identIs(bs.value, @"none")) {
        NSMutableArray<SGCBoxShadow *> *shadows = [NSMutableArray array];
        for (NSArray<SGCTok *> *group in SGCSplitCommas(SGCExpandVars(bs.value, vars) ?: @[])) {
            SGCBoxShadow *shadow = [SGCBoxShadow new];
            NSMutableArray<SGCTok *> *numbers = [NSMutableArray array], *colorTokens = [NSMutableArray array];
            for (SGCTok *t in group) {
                if (t.type == SGCTokIdent && [t.text.lowercaseString isEqualToString:@"inset"]) shadow.inset = YES;
                else if (t.type == SGCTokNumber || t.type == SGCTokDimension) [numbers addObject:t];
                else [colorTokens addObject:t];
            }
            if (numbers.count < 2) continue;
            shadow.dx = lengthOfToken(numbers[0], ctx);
            shadow.dy = lengthOfToken(numbers[1], ctx);
            shadow.blur = numbers.count > 2 ? lengthOfToken(numbers[2], ctx) : 0;
            shadow.spread = numbers.count > 3 ? lengthOfToken(numbers[3], ctx) : 0;
            CGColorRef color = SGCColor(colorTokens, s.color);
            shadow.color = color ?: CGColorRetain(s.color);
            SGCTakeCF(s, shadow.color);
            [shadows addObject:shadow];
        }
        s.boxShadows = shadows;
    }

    // filters
    SGCDecl *filter = box.decls[@"filter"];
    if (filter && !identIs(filter.value, @"none")) {
        SGCFilters *f = [SGCFilters new];
        f.brightness = 1;
        f.saturation = 1;
        f.contrast = 1;
        BOOL any = NO;
        for (SGCTok *t in SGCExpandVars(filter.value, vars) ?: @[]) {
            if (t.type != SGCTokFunc) continue;
            NSString *name = t.text.lowercaseString;
            double value = t.args.firstObject.number;
            if ([name isEqualToString:@"blur"]) { f.blur = value; any = YES; }
            else if ([name isEqualToString:@"brightness"]) { f.brightness = value; any = YES; }
            else if ([name isEqualToString:@"contrast"]) { f.contrast = value; any = YES; }
            else if ([name isEqualToString:@"saturate"]) { f.saturation = value; any = YES; }
            else if ([name isEqualToString:@"grayscale"]) { f.grayscale = value; any = YES; }
            else if ([name isEqualToString:@"sepia"]) { f.sepia = value; any = YES; }
            else if ([name isEqualToString:@"invert"]) { f.invert = value; any = YES; }
            else if ([name isEqualToString:@"hue-rotate"]) { f.hueRotate = value; any = YES; }
        }
        if (any) s.filters = f;
    }

    if (box.decls[@"transform"]) s.transformRaw = SGCExpandVars(box.decls[@"transform"].value, vars) ?: @[];
    if (box.decls[@"rotate"]) {
        SGCTok *t = SGCExpandVars(box.decls[@"rotate"].value, vars).firstObject;
        if (t.type == SGCTokDimension) s.rotateProp = t.number;
    }
    if (box.decls[@"translate"]) s.transformRaw = SGCExpandVars(box.decls[@"translate"].value, vars) ?: @[];

    SGCDecl *mix = box.decls[@"mix-blend-mode"];
    if (mix) s.blend = blendNamed(mix.value.firstObject.text.lowercaseString);
    SGCDecl *bgBlend = box.decls[@"background-blend-mode"];
    if (bgBlend && s.bgLayers.count) s.bgBlend = blendNamed(bgBlend.value.firstObject.text.lowercaseString);

    SGCDecl *clip = box.decls[@"clip-path"];
    if (clip && !identIs(clip.value, @"none")) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(clip.value, vars) ?: @[];
        if (tokens.count == 1 && tokens[0].type == SGCTokFunc) {
            SGCClipPath *path = [SGCClipPath new];
            path.raw = tokens[0].args;
            path.kind = [tokens[0].text.lowercaseString isEqualToString:@"path"];
            s.clip = path;
        }
    }

    SGCDecl *mask = box.decls[@"mask"] ?: box.decls[@"-webkit-mask"];
    if (mask && !identIs(mask.value, @"none")) {
        NSArray<SGCTok *> *tokens = SGCExpandVars(mask.value, vars) ?: @[];
        SGCMask *m = [SGCMask new];
        m.raw = tokens;
        for (SGCTok *t in tokens) {
            if (t.type != SGCTokFunc) continue;
            NSString *name = t.text.lowercaseString;
            if ([name containsString:@"linear-gradient"]) m.gradient = SGCGradientParse(t, ctx, s);
            else if ([name containsString:@"radial-gradient"]) m.dots = YES;
        }
        // the tile size rides after the slash: "... 0 0 / 2.4cqw 2.4cqw"
        BOOL inSize = NO;
        NSMutableArray<SGCTok *> *sizeTokens = [NSMutableArray array];
        for (SGCTok *t in tokens) {
            if (t.type == SGCTokDelim && [t.text isEqualToString:@"/"]) { inSize = YES; continue; }
            if (inSize && (t.type == SGCTokDimension || t.type == SGCTokNumber)) [sizeTokens addObject:t];
        }
        if (sizeTokens.count) {
            CGFloat w = lengthOfToken(sizeTokens[0], ctx);
            CGFloat h = sizeTokens.count > 1 ? lengthOfToken(sizeTokens[1], ctx) : w;
            m.tileSize = CGSizeMake(MAX(w, 1), MAX(h, 1));
        }
        s.mask = m;
    }

    // a pseudo's content: strings and attr() names, none meaning no box
    SGCDecl *content = box.decls[@"content"];
    if (content) {
        NSMutableString *resolved = [NSMutableString string];
        BOOL any = NO;
        for (SGCTok *t in SGCExpandVars(content.value, vars) ?: @[]) {
            if (t.type == SGCTokString) { [resolved appendString:t.text]; any = YES; }
            else if (t.type == SGCTokFunc && [t.text.lowercaseString isEqualToString:@"attr"]) {
                NSString *name = t.args.firstObject.text;
                [resolved appendString:box.attrs[name.lowercaseString] ?: @""];
                any = YES;
            }
        }
        if (any) s.content = resolved;
    }
}

static SGCStyle *computeStyle(SGCBox *box, SGCStyle *parent, SGCCtx *ctx) {
    SGCStyle *s = [SGCStyle new];
    s.opacity = 1;
    s.z = NSIntegerMin;
    s.align = SGCAlignStretch;
    s.selfAlign = SGCAlignStretch;
    s.shrink = 1;
    s.fontSize = parent ? parent.fontSize : 16;
    s.lineHeight = parent ? parent.lineHeight : 0;
    // the text properties css inherits ride down unless the box sets its own
    if (parent) {
        s.letterSpacing = parent.letterSpacing;
        s.wordSpacing = parent.wordSpacing;
        s.nowrap = parent.nowrap;
        s.textAlign = parent.textAlign;
        s.textForm = parent.textForm;
    }

    SGCLenCtx lctx;
    lctx.cardW = ctx.cardW;
    lctx.cardH = ctx.cardH;
    lctx.em = s.fontSize;
    lctx.rootEm = 16;

    NSDictionary *vars = box.customProps;
    computeText(s, box, vars, lctx, parent);
    lctx.em = s.fontSize;   // lengths after the font read the box's own size
    computeBox(s, box, vars, lctx, parent);
    computePaint(s, box, vars, lctx, parent);
    return s;
}

#pragma mark - the cascade walk

static void offer(NSMutableDictionary<NSString *, SGCDecl *> *decls, SGCDecl *decl,
                  NSUInteger specificity, NSInteger order) {
    SGCDecl *ranked = [SGCDecl decl:decl.prop value:decl.value important:decl.important];
    ranked.rankSpec = specificity;
    ranked.rankOrder = order;
    SGCDecl *current = decls[decl.prop];
    if (!current) { decls[decl.prop] = ranked; return; }
    if (ranked.important != current.important) {
        if (ranked.important) decls[decl.prop] = ranked;
        return;
    }
    if (ranked.rankSpec != current.rankSpec) {
        if (ranked.rankSpec > current.rankSpec) decls[decl.prop] = ranked;
        return;
    }
    if (ranked.rankOrder > current.rankOrder) decls[decl.prop] = ranked;
}

static NSArray<SGCDecl *> *inlineStyleDecls(NSString *text) {
    if (!text.length) return @[];
    NSArray<SGCRule *> *rules = SGCParseCSS([NSString stringWithFormat:@"x{%@}", text], 3, NSIntegerMax - 1);
    return rules.lastObject.decls ?: @[];
}

static void cascadeBox(SGCBox *box, SGCMatchNode *parent, NSInteger childIndex, BOOL isLast,
                       NSDictionary *inheritedVars, SGCStyle *parentStyle,
                       NSArray<SGCRule *> *rules, SGCCtx *ctx) {
    SGCMatchNode *node = [SGCMatchNode nodeWithTag:box.tag ?: @""
                                           classes:box.classList
                                             attrs:box.attrs
                                            pseudo:nil
                                              lang:box.attrs[@"lang"] ?: (parent ? parent.lang : nil)];
    node.parent = parent;
    node.childIndex = childIndex;
    node.isLast = isLast;

    NSMutableDictionary<NSString *, SGCDecl *> *decls = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, SGCDecl *> *beforeDecls = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, SGCDecl *> *afterDecls = [NSMutableDictionary dictionary];
    for (SGCRule *rule in rules) {
        if (!SGCRuleMatches(rule, node)) continue;
        NSMutableDictionary *target = decls;
        if (rule.pseudoName) target = [rule.pseudoName isEqualToString:@"before"] ? beforeDecls : afterDecls;
        for (SGCDecl *decl in rule.decls) offer(target, decl, rule.specificity, rule.order);
    }
    for (SGCDecl *decl in inlineStyleDecls(box.attrs[@"style"]))
        offer(decls, decl, 1 << 20, NSIntegerMax - 1);
    box.decls = decls;

    NSMutableDictionary<NSString *, NSArray<SGCTok *> *> *custom = inheritedVars ?
        [inheritedVars mutableCopy] : [NSMutableDictionary dictionary];
    for (SGCDecl *decl in decls.allValues)
        if ([decl.prop hasPrefix:@"--"]) custom[decl.prop] = decl.value;
    box.customProps = custom;

    box.style = computeStyle(box, parentStyle, ctx);
    if (box.style.display == SGCDisplayInlineBlock) box.isAtomic = YES;

    // pseudo elements from an earlier pass leave; the fresh ones are built below
    for (NSUInteger which = 0; which < 2; which++) {
        SGCBox *stale = which == 0 ? box.before : box.after;
        if (!stale) continue;
        [box.children removeObject:stale];
        [box.inlineItems removeObject:stale];
    }
    box.before = nil;
    box.after = nil;

    // pseudo elements: their own boxes with the originating element's attributes, so attr()
    // reads the element's data-* as css says
    for (NSUInteger which = 0; which < 2; which++) {
        NSMutableDictionary *pseudoDecls = which == 0 ? beforeDecls : afterDecls;
        if (!pseudoDecls.count) continue;
        SGCBox *pseudo = [SGCBox new];
        pseudo.tag = which == 0 ? @"pseudo-before" : @"pseudo-after";
        pseudo.isPseudo = YES;
        pseudo.attrs = box.attrs;
        pseudo.inlineItems = [NSMutableArray array];
        pseudo.children = [NSMutableArray array];
        pseudo.decls = pseudoDecls;
        NSMutableDictionary *pseudoCustom = [custom mutableCopy];
        for (SGCDecl *decl in pseudoDecls.allValues)
            if ([decl.prop hasPrefix:@"--"]) pseudoCustom[decl.prop] = decl.value;
        pseudo.customProps = pseudoCustom;
        pseudo.style = computeStyle(pseudo, box.style, ctx);
        if (pseudo.style.display == SGCDisplayNone || !pseudo.style.content.length) continue;
        // always a child, so the paint walk reaches it; an inline one also rides the paragraph
        BOOL inline_ = pseudo.style.display == SGCDisplayInline || pseudo.style.display == SGCDisplayInlineBlock;
        if (which == 0) {
            [box.children insertObject:pseudo atIndex:0];
            if (inline_) [box.inlineItems insertObject:pseudo atIndex:0];
            box.before = pseudo;
        } else {
            [box.children addObject:pseudo];
            if (inline_) [box.inlineItems addObject:pseudo];
            box.after = pseudo;
        }
        if (pseudo.style.display == SGCDisplayInlineBlock) pseudo.isAtomic = YES;
    }

    NSInteger index = 0;
    for (SGCBox *child in box.children) {
        cascadeBox(child, node, index++, index == (NSInteger)box.children.count - 1,
                   custom, box.style, rules, ctx);
    }
}

void SGCCascade(SGCBox *root, NSArray<SGCRule *> *rules, NSDictionary<NSString *, NSArray<SGCTok *> *> *seedVars, SGCCtx *ctx) {
    cascadeBox(root, nil, 0, YES, seedVars, nil, rules, ctx);
}
