// The CSS side: a tokenizer good enough for the declarations the lock-screen styles carry
// (functions with balanced parens, quoted strings, comments), a calc evaluator, colours, the
// selector grammar the styles use, and the rule parser. The catalog is the contract, so this
// covers what it uses: :is/:not/:lang/:nth-child/:last-child, attribute tests, child and
// sibling combinators, min/max/clamp/mod/sqrt in calc, and custom properties passed through.
#import "SGCardPrivate.h"

#pragma mark - tokens

@implementation SGCTok
+ (SGCTok *)tokWithType:(SGCTokType)type text:(NSString *)text number:(double)number unit:(NSString *)unit {
    SGCTok *t = [SGCTok new];
    t.type = type;
    t.text = text;
    t.number = number;
    t.unit = unit;
    return t;
}

+ (SGCTok *)func:(NSString *)name args:(NSArray<SGCTok *> *)args {
    SGCTok *t = [SGCTok new];
    t.type = SGCTokFunc;
    t.text = name;
    t.args = args ?: @[];
    return t;
}

- (NSString *)debugString {
    switch (self.type) {
        case SGCTokIdent: return self.text;
        case SGCTokNumber: return [NSString stringWithFormat:@"%g", self.number];
        case SGCTokDimension: return [NSString stringWithFormat:@"%g%@", self.number, self.unit];
        case SGCTokPercent: return [NSString stringWithFormat:@"%g%%", self.number];
        case SGCTokString: return [NSString stringWithFormat:@"\"%@\"", self.text];
        case SGCTokHash: return [NSString stringWithFormat:@"#%@", self.text];
        case SGCTokDelim: return self.text;
        case SGCTokComma: return @",";
        case SGCTokFunc: {
            NSMutableArray<NSString *> *parts = [NSMutableArray array];
            for (SGCTok *a in self.args) [parts addObject:a.debugString];
            return [NSString stringWithFormat:@"%@(%@)", self.text, [parts componentsJoinedByString:@" "]];
        }
        default: return @"";
    }
}
@end

static BOOL identStart(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '-' || c >= 0x80;
}

static BOOL identChar(unichar c) {
    return identStart(c) || (c >= '0' && c <= '9');
}

NSArray<SGCTok *> *SGCTokenize(NSString *text) {
    NSMutableArray<SGCTok *> *out = [NSMutableArray array];
    NSUInteger len = text.length, i = 0;
    while (i < len) {
        unichar c = [text characterAtIndex:i];
        if (c == '/' && i + 1 < len && [text characterAtIndex:i + 1] == '*') {
            NSUInteger end = [text rangeOfString:@"*/" options:0 range:NSMakeRange(i + 2, len - i - 2)].location;
            i = end == NSNotFound ? len : end + 2;
            continue;
        }
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; continue; }
        if (c == ',') { [out addObject:[SGCTok tokWithType:SGCTokComma text:@"," number:0 unit:nil]]; i++; continue; }
        if (c == ')') { i++; continue; }   // a closer the opener below already consumed
        if (c == '(') {
            NSUInteger depth = 1, j = i + 1;
            while (j < len && depth) {
                unichar d = [text characterAtIndex:j];
                if (d == '(') depth++;
                else if (d == ')') depth--;
                j++;
            }
            NSString *inside = j > i + 2 ? [text substringWithRange:NSMakeRange(i + 1, j - i - 2)] : @"";
            [out addObject:[SGCTok func:@"" args:SGCTokenize(inside)]];
            i = j;
            continue;
        }
        if (c == '\'' || c == '"') {
            NSMutableString *s = [NSMutableString string];
            i++;
            while (i < len) {
                unichar d = [text characterAtIndex:i];
                if (d == c) { i++; break; }
                if (d == '\\' && i + 1 < len) { i++; d = [text characterAtIndex:i]; }
                [s appendFormat:@"%C", d];
                i++;
            }
            [out addObject:[SGCTok tokWithType:SGCTokString text:s number:0 unit:nil]];
            continue;
        }
        if (c == '#') {
            NSUInteger j = i + 1;
            while (j < len && identChar([text characterAtIndex:j])) j++;
            [out addObject:[SGCTok tokWithType:SGCTokHash text:[text substringWithRange:NSMakeRange(i + 1, j - i - 1)] number:0 unit:nil]];
            i = j;
            continue;
        }
        if ((c >= '0' && c <= '9') || ((c == '.' || ((c == '+' || c == '-') && i + 1 < len)) && i + 1 < len &&
                                       [[NSCharacterSet decimalDigitCharacterSet] characterIsMember:[text characterAtIndex:i + 1]])) {
            NSUInteger j = i + 1;
            BOOL dot = (c == '.');
            while (j < len) {
                unichar d = [text characterAtIndex:j];
                if (d >= '0' && d <= '9') { j++; continue; }
                if (d == '.' && !dot) { dot = YES; j++; continue; }
                break;
            }
            double value = [text substringWithRange:NSMakeRange(i, j - i)].doubleValue;
            if (j < len && [text characterAtIndex:j] == '%') {
                [out addObject:[SGCTok tokWithType:SGCTokPercent text:nil number:value unit:@"%"]];
                i = j + 1;
                continue;
            }
            NSUInteger uStart = j;
            while (j < len && identChar([text characterAtIndex:j])) j++;
            if (j > uStart) {
                [out addObject:[SGCTok tokWithType:SGCTokDimension text:nil number:value
                                              unit:[text substringWithRange:NSMakeRange(uStart, j - uStart)]]];
            } else {
                [out addObject:[SGCTok tokWithType:SGCTokNumber text:nil number:value unit:nil]];
            }
            i = j;
            continue;
        }
        if (identStart(c)) {
            NSUInteger j = i + 1;
            while (j < len && identChar([text characterAtIndex:j])) j++;
            NSString *name = [text substringWithRange:NSMakeRange(i, j - i)];
            if (j < len && [text characterAtIndex:j] == '(') {
                NSUInteger depth = 1, k = j + 1;
                while (k < len && depth) {
                    unichar d = [text characterAtIndex:k];
                    if (d == '(') depth++;
                    else if (d == ')') depth--;
                    k++;
                }
                NSString *inside = k > j + 2 ? [text substringWithRange:NSMakeRange(j + 1, k - j - 2)] : @"";
                [out addObject:[SGCTok func:name args:SGCTokenize(inside)]];
                i = k;
            } else {
                [out addObject:[SGCTok tokWithType:SGCTokIdent text:name number:0 unit:nil]];
                i = j;
            }
            continue;
        }
        // anything else rides as a one-character delimiter: : ; > + ~ * = [ ] and the like
        [out addObject:[SGCTok tokWithType:SGCTokDelim text:[text substringWithRange:NSMakeRange(i, 1)] number:0 unit:nil]];
        i++;
    }
    return out;
}

NSString *SGCTokensText(NSArray<SGCTok *> *tokens) {
    if (!tokens.count) return @"";
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (SGCTok *t in tokens) [parts addObject:t.debugString];
    return [parts componentsJoinedByString:@" "];
}

#pragma mark - lengths, numbers, calc

double SGLengthValue(double number, NSString *unit, SGCLenCtx ctx) {
    NSString *u = unit.lowercaseString;
    if (!u.length || [u isEqualToString:@"px"] || [u isEqualToString:@"pt"]) return number;
    if ([u isEqualToString:@"cqw"]) return ctx.cardW * number / 100.0;
    if ([u isEqualToString:@"cqh"]) return ctx.cardH * number / 100.0;
    if ([u isEqualToString:@"em"]) return ctx.em * number;
    if ([u isEqualToString:@"rem"]) return ctx.rootEm * number;
    if ([u isEqualToString:@"vw"]) return ctx.cardW * number / 100.0;
    if ([u isEqualToString:@"vh"]) return ctx.cardH * number / 100.0;
    if ([u isEqualToString:@"in"]) return number * 96;
    if ([u isEqualToString:@"cm"]) return number * 96 / 2.54;
    if ([u isEqualToString:@"mm"]) return number * 96 / 25.4;
    // angles and times ride through as their number; only painters and animators read them
    return number;
}

// A recursive-descent walk over a flat token list: expr (+|-) term ((*|/) factor) factor,
// percents against base. numbersOnly turns percents into their fraction and refuses dimensions.
@interface SGCExpr : NSObject
@property (strong) NSArray<SGCTok *> *tokens;
@property NSUInteger at;
@property SGCLenCtx ctx;
@property CGFloat base;
@property BOOL numbersOnly, percent, failed;
- (double)expression;
- (double)term;
- (double)factor;
- (double)primary;
- (SGCTok *)peek;
- (SGCTok *)next;
@end

@implementation SGCExpr
- (SGCTok *)peek { return self.at < self.tokens.count ? self.tokens[self.at] : nil; }
- (SGCTok *)next { return self.at < self.tokens.count ? self.tokens[self.at++] : nil; }

- (BOOL)isOp:(NSString *)op {
    SGCTok *t = self.peek;
    return t && t.type == SGCTokDelim && [t.text isEqualToString:op];
}

- (double)expression {
    double value = [self term];
    while (!self.failed && ([self isOp:@"+"] || [self isOp:@"-"])) {
        char op = [self.next.text characterAtIndex:0];
        double right = [self term];
        value = op == '+' ? value + right : value - right;
    }
    return value;
}

- (double)term {
    double value = [self factor];
    while (!self.failed && ([self isOp:@"*"] || [self isOp:@"/"])) {
        char op = [self.next.text characterAtIndex:0];
        double right = [self factor];
        if (op == '*') value *= right;
        else if (right != 0) value /= right;
        else { self.failed = YES; value = 0; }
    }
    return value;
}

- (double)factor {
    BOOL negate = NO;
    while ([self isOp:@"+"] || [self isOp:@"-"]) {
        if ([self.next.text isEqualToString:@"-"]) negate = !negate;
    }
    double value = [self primary];
    return negate ? -value : value;
}

- (double)primary {
    SGCTok *t = [self next];
    if (!t) { self.failed = YES; return 0; }
    switch (t.type) {
        case SGCTokNumber: return t.number;
        case SGCTokPercent:
            self.percent = YES;
            return self.numbersOnly ? t.number / 100.0 : self.base * t.number / 100.0;
        case SGCTokDimension:
            if (self.numbersOnly) { self.failed = YES; return 0; }
            return SGLengthValue(t.number, t.unit, self.ctx);
        case SGCTokFunc: return [self function:t];
        default: self.failed = YES; return 0;
    }
}

// The maths functions and any parenthesised group. A var() reaching this far means the
// caller did not expand it: it fails rather than resolving to something wrong.
- (double)function:(SGCTok *)t {
    NSString *name = t.text.lowercaseString;
    if ([name isEqualToString:@"var"]) { self.failed = YES; return 0; }
    if ([name isEqualToString:@"calc"] || [name isEqualToString:@"attr"] || name.length == 0) {
        SGCExpr *inner = [SGCExpr new];
        inner.tokens = t.args;
        inner.ctx = self.ctx;
        inner.base = self.base;
        inner.numbersOnly = self.numbersOnly;
        double value = inner.expression;
        if (inner.failed) self.failed = YES;
        return value;
    }
    if ([name isEqualToString:@"sqrt"]) {
        SGCExpr *inner = [SGCExpr new];
        inner.tokens = t.args;
        inner.ctx = self.ctx;
        inner.base = self.base;
        inner.numbersOnly = YES;
        double value = inner.expression;
        if (inner.failed) self.failed = YES;
        return value < 0 ? 0 : sqrt(value);
    }
    if ([name isEqualToString:@"min"] || [name isEqualToString:@"max"]) {
        double best = 0;
        BOOL first = YES;
        BOOL failed = NO;
        for (NSArray<SGCTok *> *group in SGCSplitCommas(t.args)) {
            SGCExpr *inner = [SGCExpr new];
            inner.tokens = group;
            inner.ctx = self.ctx;
            inner.base = self.base;
            inner.numbersOnly = self.numbersOnly;
            double value = inner.expression;
            if (inner.failed) { failed = YES; continue; }
            if (first || ([name isEqualToString:@"min"] ? value < best : value > best)) best = value;
            first = NO;
        }
        if (failed) self.failed = YES;
        return best;
    }
    // mod(a, b): a reduced by b into [0, b)
    if ([name isEqualToString:@"mod"] || [name isEqualToString:@"rem"]) {
        NSArray<NSArray<SGCTok *> *> *groups = SGCSplitCommas(t.args);
        if (groups.count != 2) { self.failed = YES; return 0; }
        double pair[2];
        for (NSUInteger i = 0; i < 2; i++) {
            SGCExpr *inner = [SGCExpr new];
            inner.tokens = groups[i];
            inner.ctx = self.ctx;
            inner.base = self.base;
            inner.numbersOnly = self.numbersOnly;
            pair[i] = inner.expression;
            if (inner.failed) { self.failed = YES; return 0; }
        }
        if (pair[1] == 0) { self.failed = YES; return 0; }
        double value = pair[0] - pair[1] * floor(pair[0] / pair[1]);
        return value;
    }
    // clamp(min, preferred, max)
    if ([name isEqualToString:@"clamp"]) {
        NSArray<NSArray<SGCTok *> *> *groups = SGCSplitCommas(t.args);
        if (groups.count != 3) { self.failed = YES; return 0; }
        double values[3];
        for (NSUInteger i = 0; i < 3; i++) {
            SGCExpr *inner = [SGCExpr new];
            inner.tokens = groups[i];
            inner.ctx = self.ctx;
            inner.base = self.base;
            inner.numbersOnly = self.numbersOnly;
            values[i] = inner.expression;
            if (inner.failed) { self.failed = YES; return 0; }
        }
        return MAX(values[0], MIN(values[2], values[1]));
    }
    self.failed = YES;
    return 0;
}
@end

NSArray<NSArray<SGCTok *> *> *SGCSplitCommas(NSArray<SGCTok *> *tokens) {
    NSMutableArray<NSArray<SGCTok *> *> *groups = [NSMutableArray array];
    NSMutableArray<SGCTok *> *current = [NSMutableArray array];
    for (SGCTok *t in tokens) {
        if (t.type == SGCTokComma) { [groups addObject:current]; current = [NSMutableArray array]; continue; }
        [current addObject:t];
    }
    [groups addObject:current];
    return groups;
}

static BOOL evalTokens(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base, BOOL numbersOnly,
                       BOOL *outPercent, double *outValue) {
    SGCExpr *expr = [SGCExpr new];
    expr.tokens = tokens;
    expr.ctx = ctx;
    expr.base = base;
    expr.numbersOnly = numbersOnly;
    double value = expr.expression;
    if (expr.failed || expr.at != tokens.count) return NO;
    if (outPercent) *outPercent = expr.percent;
    *outValue = value;
    return YES;
}

BOOL SGCLength(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat *out) {
    BOOL percent = NO;
    double value = 0;
    if (!evalTokens(tokens, ctx, 0, NO, &percent, &value)) return NO;
    if (percent) return NO;
    *out = value;
    return YES;
}

BOOL SGCNumber(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, double *out) {
    return evalTokens(tokens, ctx, 0, YES, NULL, out);
}

BOOL SGCLenOrPercent(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base, CGFloat *out) {
    double value = 0;
    if (!evalTokens(tokens, ctx, base, NO, NULL, &value)) return NO;
    *out = value;
    return YES;
}

#pragma mark - colours

static NSDictionary<NSString *, NSArray<NSNumber *> *> *namedColors(void) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"white": @[@255, @255, @255, @1], @"black": @[@0, @0, @0, @1],
            @"red": @[@255, @0, @0, @1], @"green": @[@0, @128, @0, @1], @"blue": @[@0, @0, @255, @1],
            @"yellow": @[@255, @255, @0, @1], @"orange": @[@255, @165, @0, @1],
            @"purple": @[@128, @0, @128, @1], @"pink": @[@255, @192, @203, @1],
            @"gray": @[@128, @128, @128, @1], @"grey": @[@128, @128, @128, @1],
            @"silver": @[@192, @192, @192, @1], @"maroon": @[@128, @0, @0, @1],
            @"navy": @[@0, @0, @128, @1], @"teal": @[@0, @128, @128, @1],
            @"olive": @[@128, @128, @0, @1], @"lime": @[@0, @255, @0, @1],
            @"aqua": @[@0, @255, @255, @1], @"cyan": @[@0, @255, @255, @1],
            @"magenta": @[@255, @0, @255, @1], @"fuchsia": @[@255, @0, @255, @1],
            @"gold": @[@255, @215, @0, @1], @"brown": @[@165, @42, @42, @1],
            @"indigo": @[@75, @0, @130, @1], @"violet": @[@238, @130, @238, @1],
            @"crimson": @[@220, @20, @60, @1], @"tomato": @[@255, @99, @71, @1],
            @"coral": @[@255, @127, @80, @1], @"salmon": @[@250, @128, @114, @1],
            @"khaki": @[@240, @230, @140, @1], @"beige": @[@245, @245, @220, @1],
            @"ivory": @[@255, @255, @240, @1], @"azure": @[@240, @255, @255, @1],
            @"turquoise": @[@64, @224, @208, @1], @"orchid": @[@218, @112, @214, @1],
            @"plum": @[@221, @160, @221, @1], @"tan": @[@210, @180, @140, @1],
            @"skyblue": @[@135, @206, @235, @1], @"steelblue": @[@70, @130, @180, @1],
            @"darkred": @[@139, @0, @0, @1], @"darkgreen": @[@0, @100, @0, @1],
            @"darkblue": @[@0, @0, @139, @1], @"darkgray": @[@169, @169, @169, @1],
            @"darkgrey": @[@169, @169, @169, @1], @"dimgray": @[@105, @105, @105, @1],
            @"dimgrey": @[@105, @105, @105, @1], @"slategray": @[@112, @128, @144, @1],
            @"lightslategray": @[@119, @136, @153, @1], @"lightgray": @[@211, @211, @211, @1],
            @"lightgrey": @[@211, @211, @211, @1], @"gainsboro": @[@220, @220, @220, @1],
            @"whitesmoke": @[@245, @245, @245, @1], @"rebeccapurple": @[@102, @51, @153, @1],
            @"transparent": @[@0, @0, @0, @0],
        };
    });
    return map;
}

static int hexValue(unichar c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

CGColorRef SGCColorFromString(NSString *string, CGColorRef currentColor) {
    string = string.lowercaseString;
    if (!string.length) return NULL;
    if ([string isEqualToString:@"currentcolor"]) return currentColor ? CGColorRetain(currentColor) : NULL;
    if ([string isEqualToString:@"transparent"]) {
        static CGColorRef clear;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ clear = CGColorCreateGenericRGB(0, 0, 0, 0); });
        return CGColorRetain(clear);
    }
    if ([string hasPrefix:@"#"]) {
        NSString *hex = [string substringFromIndex:1];
        if (hex.length != 3 && hex.length != 4 && hex.length != 6 && hex.length != 8) return NULL;
        NSMutableArray<NSNumber *> *parts = [NSMutableArray array];
        if (hex.length <= 4) {
            for (NSUInteger i = 0; i < hex.length; i++) {
                int v = hexValue([hex characterAtIndex:i]);
                if (v < 0) return NULL;
                [parts addObject:@(v * 16 + v)];
            }
        } else {
            for (NSUInteger i = 0; i + 1 < hex.length; i += 2) {
                int hi = hexValue([hex characterAtIndex:i]), lo = hexValue([hex characterAtIndex:i + 1]);
                if (hi < 0 || lo < 0) return NULL;
                [parts addObject:@(hi * 16 + lo)];
            }
        }
        CGFloat alpha = parts.count > 3 ? [parts[3] doubleValue] / 255.0 : 1;
        return CGColorCreateGenericRGB([parts[0] doubleValue] / 255.0, [parts[1] doubleValue] / 255.0,
                                       [parts[2] doubleValue] / 255.0, alpha);
    }
    NSArray *named = namedColors()[string];
    if (named) return CGColorCreateGenericRGB([named[0] doubleValue] / 255.0, [named[1] doubleValue] / 255.0,
                                              [named[2] doubleValue] / 255.0, [named[3] doubleValue]);
    return NULL;
}

CGColorRef SGCColorFuncRGB(NSArray<SGCTok *> *args) {
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    CGFloat alpha = 1;
    BOOL sawAlpha = NO;
    for (SGCTok *t in args) {
        if (t.type == SGCTokComma) continue;
        if (t.type == SGCTokDelim && [t.text isEqualToString:@"/"]) { sawAlpha = YES; continue; }
        double v = NAN;
        if (t.type == SGCTokNumber) v = t.number;
        else if (t.type == SGCTokPercent) v = t.number / 100.0 * 255;
        else if (t.type == SGCTokFunc) return NULL;   // a var or a nested colour comes back for another pass
        if (isnan(v)) return NULL;
        if (sawAlpha) { alpha = v > 1 ? v / 255.0 : v; break; }
        [values addObject:@(v)];
    }
    if (values.count < 3) return NULL;
    return CGColorCreateGenericRGB([values[0] doubleValue] / 255.0, [values[1] doubleValue] / 255.0,
                                   [values[2] doubleValue] / 255.0, alpha);
}

// color-mix(in oklab|in srgb, A p1?, B p2?): a straight mix of the two colours, gamma space.
// A true oklab conversion is more than the difference it makes at card sizes.
CGColorRef SGCColorMix(NSArray<SGCTok *> *args, CGColorRef currentColor) {
    NSArray<NSArray<SGCTok *> *> *groups = SGCSplitCommas(args);
    if (groups.count < 3) return NULL;
    CGFloat shares[2] = {1, 1};
    BOOL shareSet = NO;
    for (NSUInteger side = 1; side <= 2; side++) {
        NSArray<SGCTok *> *tokens = groups[side];
        SGCTok *last = tokens.lastObject;
        if (tokens.count > 1 && (last.type == SGCTokPercent || last.type == SGCTokNumber)) {
            shares[side - 1] = last.number / 100.0;
            shareSet = YES;
        }
    }
    CGFloat total = shares[0] + shares[1];
    CGFloat w1 = total > 0 ? shares[0] / total : 0.5;
    if (!shareSet) {
        // one share given, none for the other side: css says the other takes what is left
        BOOL firstHas = groups[1].count > 1 && groups[1].lastObject.type == SGCTokPercent;
        if (firstHas) w1 = shares[0];
    }
    CGColorRef a = SGCColor(groups[1], currentColor);
    CGColorRef b = SGCColor(groups[2], currentColor);
    if (!a || !b) { if (a) CGColorRelease(a); if (b) CGColorRelease(b); return NULL; }
    const CGFloat *ca = CGColorGetComponents(a), *cb = CGColorGetComponents(b);
    NSUInteger na = CGColorGetNumberOfComponents(a), nb = CGColorGetNumberOfComponents(b);
    CGFloat ra = na >= 3 ? ca[0] : ca[0], ga = na >= 3 ? ca[1] : ca[0], ba = na >= 3 ? ca[2] : ca[0];
    CGFloat aa = na == 2 ? ca[1] : (na >= 4 ? ca[3] : 1);
    CGFloat rb = nb >= 3 ? cb[0] : cb[0], gb = nb >= 3 ? cb[1] : cb[0], bb = nb >= 3 ? cb[2] : cb[0];
    CGFloat ab = nb == 2 ? cb[1] : (nb >= 4 ? cb[3] : 1);
    CGColorRef out = CGColorCreateGenericRGB(ra * w1 + rb * (1 - w1), ga * w1 + gb * (1 - w1),
                                             ba * w1 + bb * (1 - w1), aa * w1 + ab * (1 - w1));
    CGColorRelease(a);
    CGColorRelease(b);
    return out;
}

CGColorRef SGCColor(NSArray<SGCTok *> *tokens, CGColorRef currentColor) {
    tokens = SGCStrip(tokens);
    if (tokens.count != 1) return NULL;
    SGCTok *t = tokens[0];
    if (t.type == SGCTokHash) return SGCColorFromString([@"#" stringByAppendingString:t.text], currentColor);
    if (t.type == SGCTokIdent) return SGCColorFromString(t.text, currentColor);
    if (t.type == SGCTokString) return SGCColorFromString(t.text, currentColor);
    if (t.type == SGCTokFunc) {
        NSString *name = t.text.lowercaseString;
        if ([name isEqualToString:@"rgb"] || [name isEqualToString:@"rgba"]) return SGCColorFuncRGB(t.args);
        if ([name isEqualToString:@"colormix"]) return SGCColorMix(t.args, currentColor);
        if ([name isEqualToString:@"var"]) return NULL;   // vars are expanded before values resolve
    }
    return NULL;
}

BOOL SGCColorStop(NSArray<SGCTok *> *tokens, SGCLenCtx ctx, CGFloat base,
                  CGColorRef _Nullable * _Nullable colorOut, CGFloat * _Nullable firstOut, CGFloat * _Nullable secondOut) {
    NSMutableArray<SGCTok *> *color = [NSMutableArray array], *positions = [NSMutableArray array];
    for (SGCTok *t in tokens) {
        if (t.type == SGCTokPercent || t.type == SGCTokDimension || t.type == SGCTokNumber) [positions addObject:t];
        else if (t.type == SGCTokDelim) continue;
        else [color addObject:t];
    }
    // a bare number before a colour would be nonsense, but a lone one can be a position only
    if (color.count == 1 && positions.count >= 1 && color[0].type == SGCTokNumber) {
        [positions insertObject:color[0] atIndex:0];
        [color removeAllObjects];
    }
    CGColorRef colorRef = SGCColor(color, NULL);
    if (!colorRef) return NO;
    if (colorOut) *colorOut = colorRef; else CGColorRelease(colorRef);
    if (firstOut) {
        CGFloat first = NAN, second = NAN;
        if (positions.count && !SGCLenOrPercent(@[positions[0]], ctx, base, &first)) first = NAN;
        if (positions.count > 1 && !SGCLenOrPercent(@[positions[1]], ctx, base, &second)) second = NAN;
        *firstOut = first;
        if (secondOut) *secondOut = second;
    }
    return YES;
}

NSArray<SGCTok *> *SGCStrip(NSArray<SGCTok *> *tokens) {
    if (tokens.count == 1 && tokens[0].type == SGCTokFunc && tokens[0].text.length == 0) return tokens[0].args;
    return tokens;
}

// One pass of var() substitution. Unresolvable names leave the whole value dead: css calls
// that invalid, and drawing half a value would be worse than none.
static NSArray<SGCTok *> * _Nullable expandTokens(NSArray<SGCTok *> *tokens,
                                                  NSDictionary<NSString *, NSArray<SGCTok *> *> *vars,
                                                  NSInteger depth) {
    if (depth > 8) return nil;
    BOOL changed = NO;
    NSMutableArray<SGCTok *> *out = [NSMutableArray array];
    for (SGCTok *t in tokens) {
        if (t.type == SGCTokFunc && [t.text.lowercaseString isEqualToString:@"var"]) {
            NSArray<NSArray<SGCTok *> *> *groups = SGCSplitCommas(t.args);
            NSString *name = groups.firstObject.firstObject.text;
            NSArray<SGCTok *> *found = name ? vars[name] : nil;
            if (!found && groups.count > 1) found = groups[1];   // the fallback, itself var-free or not
            if (!found) return nil;
            NSArray<SGCTok *> *expanded = expandTokens(found, vars, depth + 1);
            if (!expanded) return nil;
            [out addObjectsFromArray:expanded];
            changed = YES;
            continue;
        }
        if (t.type == SGCTokFunc && t.args.count) {
            NSArray<SGCTok *> *args = expandTokens(t.args, vars, depth + 1);
            if (!args) return nil;
            [out addObject:[SGCTok func:t.text args:args]];
            changed = YES;
            continue;
        }
        [out addObject:t];
    }
    return changed ? out : tokens;
}

NSArray<SGCTok *> * _Nullable SGCExpandVars(NSArray<SGCTok *> *tokens,
                                            NSDictionary<NSString *, NSArray<SGCTok *> *> *vars) {
    if (!vars.count) return tokens;
    return expandTokens(tokens, vars, 0);
}
