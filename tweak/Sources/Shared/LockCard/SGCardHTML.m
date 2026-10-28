// The template side: mustache over the data dictionary, then the HTML subset to a box tree.
// Mustache parses to a node tree first and renders the tree against the scope stack, so
// sections nest and arrays iterate the way the catalog's templates need. The HTML parser is
// strict about what it accepts but never fatal -- a bad tag renders as a span, an unknown
// name as nothing, with a warning the caller can log.
#import "SGCardPrivate.h"

#pragma mark - mustache

static NSString *escapeHTML(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        switch (c) {
            case '&': [out appendString:@"&amp;"]; break;
            case '<': [out appendString:@"&lt;"]; break;
            case '>': [out appendString:@"&gt;"]; break;
            case '"': [out appendString:@"&quot;"]; break;
            case '\'': [out appendString:@"&#39;"]; break;
            default: [out appendFormat:@"%C", c];
        }
    }
    return out;
}

@interface SGCMNode : NSObject
@property BOOL isText, isSection, isInverted;
@property (copy) NSString *text, *name;
@property (copy) NSArray *children;   // SGCMNode
@end

@implementation SGCMNode
@end

// The value a section or name names: strings render, arrays iterate, dictionaries scope.
static id sectionValue(NSArray<NSDictionary *> *scopes, NSString *name) {
    for (NSDictionary *scope in scopes.reverseObjectEnumerator) {
        id value = scope[name];
        if (value) return value;
    }
    return nil;
}

// Splits the template into nodes; sections recurse to their closer.
static NSMutableArray<SGCMNode *> *mustacheParse(NSString *text, NSUInteger *at, NSMutableArray<NSString *> *warnings, NSString *stopAt) {
    NSMutableArray<SGCMNode *> *nodes = [NSMutableArray array];
    NSUInteger len = text.length, i = *at;
    NSMutableString *plain = [NSMutableString string];
    while (i < len) {
        NSRange open = [text rangeOfString:@"{{" options:0 range:NSMakeRange(i, len - i)];
        NSUInteger literalEnd = open.location == NSNotFound ? len : open.location;
        [plain appendString:[text substringWithRange:NSMakeRange(i, literalEnd - i)]];
        i = literalEnd;
        if (open.location == NSNotFound) break;
        BOOL triple = open.location + 2 < len && [text characterAtIndex:open.location + 2] == '{';
        NSString *closer = triple ? @"}}}" : @"}}";
        NSRange close = [text rangeOfString:closer options:0
                                      range:NSMakeRange(open.location + (triple ? 3 : 2), len - open.location - (triple ? 3 : 2))];
        if (close.location == NSNotFound) {
            [warnings addObject:@"mustache: an open brace with no closer"];
            break;
        }
        if (plain.length) {
            SGCMNode *node = [SGCMNode new];
            node.isText = YES;
            node.text = plain;
            [nodes addObject:node];
            plain = [NSMutableString string];
        }
        NSString *inside = [text substringWithRange:NSMakeRange(open.location + (triple ? 3 : 2),
                                                                close.location - open.location - (triple ? 3 : 2))];
        NSCharacterSet *spaces = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        inside = [[inside componentsSeparatedByCharactersInSet:spaces] componentsJoinedByString:@""];
        i = close.location + closer.length;
        if (!inside.length) continue;
        unichar head = [inside characterAtIndex:0];
        if (head == '/' ) {
            if (stopAt && [stopAt isEqualToString:[inside substringFromIndex:1]]) { *at = i; return nodes; }
            [warnings addObject:[NSString stringWithFormat:@"mustache: {{/%@} without its opener", [inside substringFromIndex:1]]];
            continue;
        }
        if (head == '#' || head == '^') {
            NSString *name = [inside substringFromIndex:1];
            NSUInteger childAt = i;
            NSArray *children = mustacheParse(text, &childAt, warnings, name);
            i = childAt;
            SGCMNode *node = [SGCMNode new];
            node.isSection = YES;
            node.isInverted = head == '^';
            node.name = name;
            node.children = children;
            [nodes addObject:node];
            continue;
        }
        SGCMNode *node = [SGCMNode new];
        node.name = inside;
        node.text = triple ? nil : @"";   // text nil marks a raw interpolation
        [nodes addObject:node];
    }
    if (plain.length) {
        SGCMNode *node = [SGCMNode new];
        node.isText = YES;
        node.text = plain;
        [nodes addObject:node];
    }
    *at = i;
    if (stopAt) [warnings addObject:[NSString stringWithFormat:@"mustache: {{#%@} never closed", stopAt]];
    return nodes;
}

static void mustacheRenderNode(SGCMNode *node, NSMutableArray<NSDictionary *> *scopes,
                               NSMutableString *out, NSMutableArray<NSString *> *warnings);

static void mustacheRenderChildren(NSArray *children, NSMutableArray<NSDictionary *> *scopes,
                                   NSMutableString *out, NSMutableArray<NSString *> *warnings) {
    for (SGCMNode *child in children) mustacheRenderNode(child, scopes, out, warnings);
}

static void mustacheRenderNode(SGCMNode *node, NSMutableArray<NSDictionary *> *scopes,
                               NSMutableString *out, NSMutableArray<NSString *> *warnings) {
    if (node.isText) { [out appendString:node.text]; return; }
    if (!node.isSection) {
        id value = sectionValue(scopes, node.name);
        if (!value) {
            [warnings addObject:[NSString stringWithFormat:@"mustache: no data for %@", node.name]];
            return;
        }
        NSString *string = [value isKindOfClass:NSString.class] ? value :
                           ([value isKindOfClass:NSNumber.class] ? [value stringValue] : nil);
        if (string) [out appendString:node.text ? escapeHTML(string) : string];
        return;
    }
    id value = sectionValue(scopes, node.name);
    BOOL truthy = NO;
    if ([value isKindOfClass:NSString.class]) truthy = [(NSString *)value length] > 0 && ![(NSString *)value isEqualToString:@"0"];
    else if ([value isKindOfClass:NSArray.class]) truthy = [(NSArray *)value count] > 0;
    else if ([value isKindOfClass:NSDictionary.class]) truthy = YES;
    else if ([value isKindOfClass:NSNumber.class]) truthy = [value doubleValue] != 0;
    if (node.isInverted) {
        if (!truthy) mustacheRenderChildren(node.children, scopes, out, warnings);
        return;
    }
    if (!truthy) return;
    if ([value isKindOfClass:NSArray.class]) {
        for (id item in value) {
            NSMutableArray *inner = [scopes mutableCopy];
            if ([item isKindOfClass:NSDictionary.class]) [inner addObject:item];
            if (item) [inner addObject:@{node.name: item}];
            mustacheRenderChildren(node.children, inner, out, warnings);
        }
    } else if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *inner = [scopes mutableCopy];
        [inner addObject:value];
        mustacheRenderChildren(node.children, inner, out, warnings);
    } else {
        NSMutableArray *inner = [scopes mutableCopy];
        [inner addObject:@{node.name: value}];
        mustacheRenderChildren(node.children, inner, out, warnings);
    }
}

NSString *SGCMustache(NSString *templateText, NSDictionary *data, NSMutableArray<NSString *> *warnings) {
    if (!templateText.length) return @"";
    if (!warnings) warnings = [NSMutableArray array];
    NSUInteger at = 0;
    NSArray *nodes = mustacheParse(templateText, &at, warnings, nil);
    NSMutableString *out = [NSMutableString string];
    NSMutableArray<NSDictionary *> *scopes = [data ?: @{} mutableCopy];
    mustacheRenderChildren(nodes, scopes, out, warnings);
    return out;
}

#pragma mark - html

// The elements the subset allows; anything else renders its children where it stood, with
// script and style dropped outright.
static BOOL allowedTag(NSString *tag) {
    static NSArray *allowed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = @[@"div", @"span", @"p", @"b", @"i", @"em", @"strong", @"small", @"br",
                    @"section", @"header", @"footer", @"main", @"article", @"aside", @"figure",
                    @"figcaption", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"blockquote", @"q",
                    @"hr", @"img", @"wbr"];
    });
    return [allowed containsObject:tag];
}

static BOOL voidTag(NSString *tag) {
    return [tag isEqualToString:@"br"] || [tag isEqualToString:@"hr"] ||
           [tag isEqualToString:@"img"] || [tag isEqualToString:@"wbr"];
}

static NSString *decodeEntities(NSString *text) {
    if (![text containsString:@"&"]) return text;
    NSMutableString *out = [text mutableCopy];
    NSDictionary *named = @{@"amp": @"&", @"lt": @"<", @"gt": @">", @"quot": @"\"",
                            @"apos": @"'", @"nbsp": @"\u00a0", @"hellip": @"\u2026", @"mdash": @"\u2014",
                            @"ndash": @"\u2013", @"laquo": @"\u00ab", @"raquo": @"\u00bb", @"middot": @"\u00b7",
                            @"bull": @"\u2022", @"times": @"\u00d7", @"copy": @"\u00a9", @"deg": @"\u00b0"};
    NSUInteger at = 0;
    while (at < out.length) {
        NSRange amp = [out rangeOfString:@"&" options:0 range:NSMakeRange(at, out.length - at)];
        if (amp.location == NSNotFound) break;
        NSUInteger window = MIN(out.length - amp.location, 12);
        NSRange semi = [out rangeOfString:@";" options:0 range:NSMakeRange(amp.location, window)];
        if (semi.location == NSNotFound) { at = amp.location + 1; continue; }
        NSString *name = [out substringWithRange:NSMakeRange(amp.location + 1, semi.location - amp.location - 1)];
        NSString *replacement = nil;
        if ([name hasPrefix:@"#"]) {
            unsigned value = 0;
            NSScanner *scanner = [NSScanner scannerWithString:name];
            [scanner setScanLocation:1];
            unsigned long long parsed = 0;
            if ([scanner scanHexLongLong:&parsed] && parsed <= 0xFFFF) {
                value = (unsigned)parsed;
                replacement = [NSString stringWithFormat:@"%C", (unichar)value];
            }
        } else {
            replacement = named[name.lowercaseString];
        }
        if (replacement) {
            [out replaceCharactersInRange:NSMakeRange(amp.location, semi.location - amp.location + 1)
                               withString:replacement];
            at = amp.location + replacement.length;
        } else {
            at = amp.location + 1;
        }
    }
    return out;
}

static void pushText(SGCBox *box, NSString *text) {
    if (!text.length) return;
    if ([box.inlineItems.lastObject isKindOfClass:NSString.class]) {
        box.inlineItems[box.inlineItems.count - 1] =
            [NSString stringWithFormat:@"%@%@", box.inlineItems.lastObject, text];
    } else {
        [box.inlineItems addObject:text];
    }
}

BOOL SGCIdentChar(unichar c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
           c == '_' || c == '-' || c >= 0x80;
}

@interface SGCFrame : NSObject
@property (strong) SGCBox *box;
@property (copy) NSString *tag;
@end

@implementation SGCFrame
@end

SGCBox *SGCParseHTML(NSString *html, NSMutableArray<NSString *> *warnings) {
    if (!warnings) warnings = [NSMutableArray array];
    SGCBox *root = [SGCBox new];
    root.tag = @"root";
    root.inlineItems = [NSMutableArray array];
    root.children = [NSMutableArray array];
    SGCFrame *rootFrame = [SGCFrame new];
    rootFrame.box = root;
    rootFrame.tag = @"root";
    NSMutableArray<SGCFrame *> *stack = [NSMutableArray arrayWithObject:rootFrame];

    void (^append)(SGCBox *) = ^(SGCBox *child) {
        SGCBox *top = stack.lastObject.box;
        [top.inlineItems addObject:child];
        [top.children addObject:child];
    };

    NSUInteger i = 0, len = html.length;
    while (i < len) {
        unichar c = [html characterAtIndex:i];
        if (c != '<') {
            NSRange next = [html rangeOfString:@"<" options:0 range:NSMakeRange(i, len - i)];
            NSUInteger end = next.location == NSNotFound ? len : next.location;
            pushText(stack.lastObject.box, decodeEntities([html substringWithRange:NSMakeRange(i, end - i)]));
            i = end;
            continue;
        }
        if (i + 2 < len && [html characterAtIndex:i + 1] == '!') {
            NSUInteger end = [html rangeOfString:@"-->" options:0 range:NSMakeRange(i, len - i)].location;
            i = end == NSNotFound ? len : end + 3;
            continue;
        }
        if (i + 1 < len && [html characterAtIndex:i + 1] == '/') {
            NSUInteger end = [html rangeOfString:@">" options:0 range:NSMakeRange(i, len - i)].location;
            if (end == NSNotFound) break;
            NSString *name = [html substringWithRange:NSMakeRange(i + 2, end - i - 2)].lowercaseString;
            i = end + 1;
            NSUInteger at = NSNotFound;
            for (NSUInteger k = stack.count; k-- > 1;)
                if ([stack[k].tag isEqualToString:name]) { at = k; break; }
            if (at != NSNotFound) [stack removeObjectsInRange:NSMakeRange(at, stack.count - at)];
            continue;
        }

        NSUInteger j = i + 1;
        while (j < len && SGCIdentChar([html characterAtIndex:j])) j++;
        if (j == i + 1) { i++; continue; }
        NSString *tag = [html substringWithRange:NSMakeRange(i + 1, j - i - 1)].lowercaseString;
        NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
        BOOL selfClose = NO;
        for (;;) {
            while (j < len && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[html characterAtIndex:j]]) j++;
            if (j >= len) break;
            unichar d = [html characterAtIndex:j];
            if (d == '>') { j++; break; }
            if (d == '/') { selfClose = YES; j++; continue; }
            NSUInteger nameStart = j;
            while (j < len && SGCIdentChar([html characterAtIndex:j])) j++;
            if (j == nameStart) { j++; continue; }
            NSString *attr = [html substringWithRange:NSMakeRange(nameStart, j - nameStart)].lowercaseString;
            while (j < len && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[html characterAtIndex:j]]) j++;
            NSString *value = @"";
            if (j < len && [html characterAtIndex:j] == '=') {
                j++;
                while (j < len && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[html characterAtIndex:j]]) j++;
                if (j < len && ([html characterAtIndex:j] == '"' || [html characterAtIndex:j] == '\'')) {
                    unichar quote = [html characterAtIndex:j];
                    j++;
                    NSUInteger valueStart = j;
                    while (j < len && [html characterAtIndex:j] != quote) j++;
                    value = [html substringWithRange:NSMakeRange(valueStart, MIN(j, len) - valueStart)];
                    j = MIN(j + 1, len);
                } else {
                    NSUInteger valueStart = j;
                    while (j < len && ![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[html characterAtIndex:j]] &&
                           [html characterAtIndex:j] != '>') j++;
                    value = [html substringWithRange:NSMakeRange(valueStart, j - valueStart)];
                }
                value = decodeEntities(value);
            }
            if ([attr isEqualToString:@"class"]) {
                NSMutableArray *both = [NSMutableArray arrayWithArray:
                                        [(attrs[@"class"] ?: @"") componentsSeparatedByString:@" "]];
                [both addObjectsFromArray:[value componentsSeparatedByString:@" "]];
                [both removeObjectsInArray:@[@""]];
                attrs[@"class"] = [both componentsJoinedByString:@" "];
            } else {
                attrs[attr] = value;
            }
        }
        i = j;

        if ([tag isEqualToString:@"script"] || [tag isEqualToString:@"style"]) {
            NSString *closer = [NSString stringWithFormat:@"</%@>", tag];
            NSUInteger end = [html rangeOfString:closer options:0 range:NSMakeRange(i, len - i)].location;
            i = end == NSNotFound ? len : end + closer.length;
            continue;
        }
        if (!allowedTag(tag)) {
            [warnings addObject:[NSString stringWithFormat:@"html: %@ renders as a span", tag]];
            continue;   // the children that follow land where the unknown tag stood
        }
        SGCBox *box = [SGCBox new];
        box.tag = tag;
        box.attrs = attrs;
        box.inlineItems = [NSMutableArray array];
        box.children = [NSMutableArray array];
        append(box);
        if (!selfClose && !voidTag(tag)) {
            SGCFrame *frame = [SGCFrame new];
            frame.box = box;
            frame.tag = tag;
            [stack addObject:frame];
        }
    }
    return root;
}

#pragma mark - the engine's own text

NSString *SGCardDefaultTemplate(void) {
    return @"<div class=\"card\" data-kind=\"{{kind}}\" data-index=\"{{index}}\" data-count=\"{{count}}\" lang=\"{{lang}}\" dir=\"{{dir}}\">"
           @"<div class=\"bg\"></div>"
           @"{{#title}}<div class=\"meta\"><span class=\"title\">{{title}}</span> <span class=\"artist\">{{artist}}</span></div>{{/title}}"
           @"{{#prev}}<div class=\"prev\" data-time=\"{{prevTime}}\">{{prev}}</div>{{/prev}}"
           @"<div class=\"line\" data-time=\"{{time}}\">{{#words}}<span class=\"w\" style=\"--i: {{i}}\">{{word}}</span> {{/words}}</div>"
           @"{{#translation}}<div class=\"tr\">{{translation}}</div>{{/translation}}"
           @"{{#next}}<div class=\"next\" data-time=\"{{nextTime}}\">{{next}}</div>{{/next}}"
           @"</div>";
}

NSString *SGCardUserAgentCSS(void) {
    // the sane floor every style stands on: the card is the whole container, and .bg is the
    // cover box unless the style paints its own background over it (the cascade decides)
    return @"* { margin: 0; padding: 0; box-sizing: border-box }"
            ".card { position: relative; width: 100cqw; height: 100cqh; overflow: hidden; color: #fff; font: 400 5cqw/1.3 system-ui }"
            ".bg { position: absolute; inset: 0; background: var(--cover) center / cover; }";
}
