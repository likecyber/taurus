// Selectors and rules: the parser for the forms the lock-screen styles use (class, tag,
// descendant, child, next sibling, later sibling, attribute tests, :is/:not/:lang/:nth-child/
// :last-child, ::before/::after) and the matcher against the laid-out tree's shadow of itself.
#import "SGCardPrivate.h"

#pragma mark - small objects

@implementation SGCAttrTest
@end

@implementation SGCCompound
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _combinator = ' ';
    _classes = @[];
    _attrs = @[];
    _pseudos = @[];
    _nested = @[];
    return self;
}
@end

@implementation SGCDecl
+ (SGCDecl *)decl:(NSString *)prop value:(NSArray<SGCTok *> *)tokens important:(BOOL)important {
    SGCDecl *d = [SGCDecl new];
    d.prop = prop;
    d.value = tokens;
    d.important = important;
    return d;
}
@end

@implementation SGCRule
@end

@implementation SGCMatchNode
+ (instancetype)nodeWithTag:(NSString *)tag classes:(NSArray<NSString *> *)classes attrs:(NSDictionary *)attrs pseudo:(NSString *)pseudo lang:(NSString *)lang {
    SGCMatchNode *n = [SGCMatchNode new];
    n.tag = tag.lowercaseString;
    n.classes = classes ?: @[];
    n.attrs = attrs ?: @{};
    n.pseudo = pseudo;
    n.lang = lang.lowercaseString;
    return n;
}
@end

#pragma mark - selector parsing

@interface SGCSelectorParse : NSObject
@property (strong) NSArray<SGCTok *> *tokens;
@property NSUInteger at;
@property BOOL failed;
@property (copy) NSString *pendingCombinator;   // the combinator before the next compound
@property (copy) NSString *pseudoName;          // ::before / ::after of the last compound
@end

static NSArray<SGCCompound *> *parseSequence(SGCSelectorParse *p, NSMutableArray<NSString *> *warnings);

static SGCCompound *parseCompound(SGCSelectorParse *p, NSMutableArray<NSString *> *warnings) {
    SGCCompound *c = [SGCCompound new];
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    NSMutableArray<SGCAttrTest *> *attrs = [NSMutableArray array];
    NSMutableArray<NSString *> *pseudos = [NSMutableArray array];
    NSMutableArray<NSArray<SGCCompound *> *> *nested = [NSMutableArray array];
    NSUInteger specificity = 0;

    for (;;) {
        SGCTok *t = p.peek;
        if (!t) break;
        if (t.type == SGCTokIdent) {
            if (c.tag || c.classes.count || c.attrs.count || c.pseudos.count) { p.failed = YES; break; }
            c.tag = t.text.lowercaseString;
            c.hasTag = YES;
            specificity += 1;
            p.at++;
            continue;
        }
        if (t.type == SGCTokDelim && [t.text isEqualToString:@"*"]) { p.at++; continue; }
        if (t.type == SGCTokDelim && [t.text isEqualToString:@"."]) {
            p.at++;
            SGCTok *name = p.next;
            if (!name || name.type != SGCTokIdent) { p.failed = YES; break; }
            [classes addObject:name.text.lowercaseString];
            specificity += 1;
            continue;
        }
        if (t.type == SGCTokDelim && [t.text isEqualToString:@"#"]) {
            p.at++;
            SGCTok *name = p.next;
            if (!name) { p.failed = YES; break; }
            specificity += 100;   // no style uses ids; one still weighs in rather than vanishing
            continue;
        }
        if (t.type == SGCTokDelim && [t.text isEqualToString:@"["]) {
            p.at++;
            SGCTok *name = p.next;
            if (!name || (name.type != SGCTokIdent && name.type != SGCTokString)) { p.failed = YES; break; }
            SGCAttrTest *test = [SGCAttrTest new];
            test.name = name.text.lowercaseString;
            test.op = 0;
            SGCTok *op = p.peek;
            if (op && op.type == SGCTokDelim) {
                NSString *o = op.text;
                if ([o isEqualToString:@"="]) {
                    p.at++;
                    test.op = '=';
                } else if ([o isEqualToString:@"^"] || [o isEqualToString:@"$"] ||
                           [o isEqualToString:@"*"] || [o isEqualToString:@"~"] || [o isEqualToString:@"|"]) {
                    p.at++;
                    SGCTok *equals = p.next;
                    if (!equals || ![equals.text isEqualToString:@"="]) { p.failed = YES; break; }
                    test.op = [o characterAtIndex:0];
                }
            }
            if (test.op) {
                SGCTok *value = p.next;
                if (!value) { p.failed = YES; break; }
                test.value = value.text.lowercaseString;
            }
            SGCTok *close = p.next;
            if (!close || ![close.text isEqualToString:@"]"]) { p.failed = YES; break; }
            [attrs addObject:test];
            specificity += 1;
            continue;
        }
        if (t.type == SGCTokDelim && [t.text isEqualToString:@":"]) {
            p.at++;
            BOOL element = NO;
            if (p.peek && p.peek.type == SGCTokDelim && [p.peek.text isEqualToString:@":"]) { p.at++; element = YES; }
            SGCTok *name = p.next;
            if (!name || (name.type != SGCTokIdent && name.type != SGCTokFunc)) { p.failed = YES; break; }
            NSString *pname = name.text.lowercaseString;
            if (element || [pname isEqualToString:@"before"] || [pname isEqualToString:@"after"]) {
                if (![pname isEqualToString:@"before"] && ![pname isEqualToString:@"after"]) { p.failed = YES; break; }
                p.pseudoName = pname;
                specificity += 1;
                continue;
            }
            if ([pname isEqualToString:@"lang"]) {
                if (name.type != SGCTokFunc || !name.args.count) { p.failed = YES; break; }
                [pseudos addObject:[NSString stringWithFormat:@"lang:%@", name.args.firstObject.text.lowercaseString]];
                specificity += 1;
                continue;
            }
            if ([pname hasPrefix:@"nth"]) {
                if (name.type != SGCTokFunc || !name.args.count) { p.failed = YES; break; }
                NSString *form = SGCTokensText(name.args);
                form = [[form componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                        componentsJoinedByString:@""].lowercaseString;
                [pseudos addObject:[NSString stringWithFormat:@"nth:%@", form]];
                specificity += 1;
                continue;
            }
            if ([pname isEqualToString:@"last-child"] || [pname isEqualToString:@"first-child"]) {
                [pseudos addObject:pname];
                specificity += 1;
                continue;
            }
            if ([pname isEqualToString:@"is"] || [pname isEqualToString:@"not"] || [pname isEqualToString:@"where"]) {
                if (name.type != SGCTokFunc) { p.failed = YES; break; }
                NSMutableArray<NSArray<SGCCompound *> *> *groups = [NSMutableArray array];
                for (NSArray<SGCTok *> *groupTokens in SGCSplitCommas(name.args)) {
                    SGCSelectorParse *inner = [SGCSelectorParse new];
                    inner.tokens = groupTokens;
                    NSArray<SGCCompound *> *group = parseSequence(inner, warnings);
                    if (inner.failed || !group.count) { p.failed = YES; break; }
                    [groups addObject:group];
                }
                if (p.failed) break;
                [nested addObject:groups];
                [pseudos addObject:pname];
                if (![pname isEqualToString:@"where"]) specificity += 1;
                continue;
            }
            // hover, focus, empty and the rest: this compound matches nothing here
            p.failed = YES;
            break;
        }
        break;
    }
    if (p.failed) return nil;
    c.classes = classes;
    c.attrs = attrs;
    c.pseudos = pseudos;
    c.nested = nested;
    c.specificity = specificity;
    return c;
}

static NSArray<SGCCompound *> *parseSequence(SGCSelectorParse *p, NSMutableArray<NSString *> *warnings) {
    NSMutableArray<SGCCompound *> *parts = [NSMutableArray array];
    for (;;) {
        SGCCompound *c = parseCompound(p, warnings);
        if (!c) { p.failed = YES; return nil; }
        c.combinator = p.pendingCombinator ? [p.pendingCombinator characterAtIndex:0] : ' ';
        p.pendingCombinator = nil;
        [parts addObject:c];
        SGCTok *t = p.peek;
        if (!t) break;
        if (t.type == SGCTokDelim && ([t.text isEqualToString:@">"] || [t.text isEqualToString:@"+"] ||
                                      [t.text isEqualToString:@"~"])) {
            p.pendingCombinator = t.text;
            p.at++;
            continue;
        }
        if (t.type == SGCTokComma) break;
        // a space between two compounds is the descendant combinator
        p.pendingCombinator = @" ";
    }
    return parts;
}

static SGCRule *takeSelector(NSArray<SGCTok *> *tokens, NSInteger sheet, NSInteger order,
                             NSMutableArray<NSString *> *warnings) {
    if (!tokens.count) return nil;
    // the tokenizer dropped the spaces a selector reads compounds by: put one back wherever two
    // plain tokens sit with nothing between, since a class or attribute list keeps its markers
    NSMutableArray<SGCTok *> *spaced = [NSMutableArray array];
    for (NSUInteger k = 0; k < tokens.count; k++) {
        BOOL boundary = k > 0 &&
            tokens[k].type != SGCTokDelim && tokens[k].type != SGCTokComma &&
            tokens[k - 1].type != SGCTokDelim && tokens[k - 1].type != SGCTokComma;
        if (boundary) [spaced addObject:[SGCTok tokWithType:SGCTokDelim text:@" " number:0 unit:nil]];
        [spaced addObject:tokens[k]];
    }
    SGCSelectorParse *p = [SGCSelectorParse new];
    p.tokens = spaced;
    NSArray<SGCCompound *> *parts = parseSequence(p, warnings);
    if (!parts || p.failed || !parts.count) {
        [warnings addObject:[NSString stringWithFormat:@"css: selector not understood: %@", SGCTokensText(tokens)]];
        return nil;
    }
    SGCRule *rule = [SGCRule new];
    rule.selector = parts;
    rule.sheet = sheet;
    rule.order = order;
    rule.decls = @[];
    rule.pseudoName = p.pseudoName;
    NSUInteger specificity = 0;
    for (SGCCompound *c in parts) specificity += c.specificity;
    rule.specificity = specificity;
    return rule;
}

NSArray<SGCRule *> *SGCParseCSS(NSString *css, NSInteger sheet, NSInteger firstOrder) {
    NSMutableArray<SGCRule *> *rules = [NSMutableArray array];
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    NSArray<SGCTok *> *tokens = SGCTokenize(css);
    NSInteger order = firstOrder;
    NSUInteger i = 0;

    auto isDelim = ^(NSUInteger index, NSString *what) {
        return index < tokens.count && tokens[index].type == SGCTokDelim &&
               [tokens[index].text isEqualToString:what];
    };

    while (i < tokens.count) {
        // at-rules and stray closers are skipped to their block's end
        if (tokens[i].type == SGCTokDelim && [tokens[i].text isEqualToString:@"@"]) {
            NSUInteger depth = 0, j = i + 1;
            for (; j < tokens.count; j++) {
                if (tokens[j].type != SGCTokDelim) continue;
                NSString *text = tokens[j].text;
                if ([text isEqualToString:@"{"]) depth++;
                else if ([text isEqualToString:@"}"]) { depth--; if (depth <= 0) { j++; break; } }
                else if ([text isEqualToString:@";"] && depth == 0) { j++; break; }
            }
            i = j;
            continue;
        }
        if (isDelim(i, "}")) { i++; continue; }

        // the selector runs to the opening brace, commas split it
        NSUInteger brace = i;
        while (brace < tokens.count && !isDelim(brace, "{")) brace++;
        if (brace >= tokens.count) break;
        NSMutableArray<SGCRule *> *statement = [NSMutableArray array];
        NSMutableArray<SGCTok *> *selectorTokens = [NSMutableArray array];
        for (NSUInteger k = i; k < brace; k++) {
            SGCTok *t = tokens[k];
            if (t.type == SGCTokDelim && [t.text isEqualToString:@","]) {
                SGCRule *rule = takeSelector(selectorTokens, sheet, order++, warnings);
                if (rule) [statement addObject:rule];
                [selectorTokens removeAllObjects];
                continue;
            }
            [selectorTokens addObject:t];
        }
        SGCRule *last = takeSelector(selectorTokens, sheet, order++, warnings);
        if (last) [statement addObject:last];

        // the declarations to the closing brace, a missing final semicolon tolerated
        NSMutableArray<SGCDecl *> *decls = [NSMutableArray array];
        NSMutableArray<SGCTok *> *value = nil;
        NSString *prop = nil;
        BOOL important = NO;
        NSUInteger j = brace + 1;
        for (; j < tokens.count && !isDelim(j, "}"); j++) {
            SGCTok *t = tokens[j];
            if (t.type == SGCTokDelim && [t.text isEqualToString:@";"]) {
                if (prop) [decls addObject:[SGCDecl decl:prop value:value ?: @[] important:important]];
                prop = nil;
                value = nil;
                important = NO;
                continue;
            }
            if (t.type == SGCTokDelim && [t.text isEqualToString:@":"] && !prop && !value) {
                if (j > 0 && (tokens[j - 1].type == SGCTokIdent || tokens[j - 1].type == SGCTokFunc)) {
                    NSString *name = tokens[j - 1].text;
                    // custom properties keep their case, everything else folds
                    prop = ([name hasPrefix:@"--"] || [name isEqualToString:@"--"]) ? name : name.lowercaseString;
                    value = [NSMutableArray array];
                }
                continue;
            }
            if (t.type == SGCTokDelim && [t.text isEqualToString:@"!"]) { important = YES; continue; }
            if (prop && value) [value addObject:t];
        }
        if (prop) [decls addObject:[SGCDecl decl:prop value:value ?: @[] important:important]];
        for (SGCRule *rule in statement) rule.decls = decls;
        [rules addObjectsFromArray:statement];
        i = j + 1;
    }
    return rules;
}

#pragma mark - matching

static BOOL compoundMatches(SGCCompound *c, SGCMatchNode *node);

static BOOL sequenceMatches(NSArray<SGCCompound *> *parts, SGCMatchNode *node) {
    // right to left: this compound here, then the combinator decides where the rest looks
    if (!parts.count) return NO;
    SGCCompound *last = parts.lastObject;
    if (!compoundMatches(last, node)) return NO;
    NSUInteger remaining = parts.count - 1;
    SGCMatchNode *at = node;
    for (NSInteger k = (NSInteger)remaining - 1; k >= 0; k--) {
        SGCCompound *part = parts[k];
        unichar combinator = parts[k + 1].combinator;
        if (combinator == '>') {
            at = at.parent;
            if (!at || !compoundMatches(part, at)) return NO;
        } else if (combinator == '+' || combinator == '~') {
            SGCMatchNode *sibling = at;
            BOOL found = NO;
            while ((sibling = sibling.prev)) {
                if (compoundMatches(part, sibling)) { at = sibling; found = YES; break; }
                if (combinator == '+') break;   // only the one before counts
            }
            if (!found) return NO;
        } else {
            SGCMatchNode *ancestor = at;
            BOOL found = NO;
            while ((ancestor = ancestor.parent)) {
                if (compoundMatches(part, ancestor)) { at = ancestor; found = YES; break; }
            }
            if (!found) return NO;
        }
    }
    return YES;
}

static BOOL nthMatches(NSString *form, NSInteger index1) {
    // an+b against a one-based index; odd, even, plain numbers and negatives all fold in here
    form = [form stringByReplacingOccurrencesOfString:@" " withString:@""];
    if ([form isEqualToString:@"odd"]) form = @"2n+1";
    if ([form isEqualToString:@"even"]) form = @"2n";
    NSInteger a = 0, b = 0;
    NSRange nAt = [form rangeOfString:@"n"];
    if (nAt.location == NSNotFound) {
        a = 0;
        b = form.integerValue;
    } else {
        NSString *left = [form substringToIndex:nAt.location];
        NSString *right = [form substringFromIndex:nAt.location + 1];
        if (left.length == 0 || [left isEqualToString:@"+"]) a = 1;
        else if ([left isEqualToString:@"-"]) a = -1;
        else a = left.integerValue;
        if (right.length) b = right.integerValue;
    }
    if (a == 0) return b == index1;
    NSInteger diff = index1 - b;
    return diff % a == 0 && diff / a >= 0;
}

static BOOL compoundMatches(SGCCompound *c, SGCMatchNode *node) {
    if (c.hasTag && ![c.tag isEqualToString:node.tag]) return NO;
    for (NSString *class in c.classes)
        if (![node.classes containsObject:class]) return NO;
    for (SGCAttrTest *test in c.attrs) {
        NSString *value = node.attrs[test.name];
        if (!value && [test.name hasPrefix:@"data-"]) {
            // attrs came through as they are; a missing key is a miss unless the test is presence-only
        }
        NSString *actual = [value.lowercaseString ?: @"" copy];
        switch (test.op) {
            case 0: if (!value) return NO; break;
            case '=': if (![actual isEqualToString:test.value]) return NO; break;
            case '^': if (![actual hasPrefix:test.value]) return NO; break;
            case '$': if (![actual hasSuffix:test.value]) return NO; break;
            case '*': if ([actual rangeOfString:test.value].location == NSNotFound) return NO; break;
            default: return NO;
        }
    }
    NSUInteger nestedAt = 0;
    for (NSString *pseudo in c.pseudos) {
        if ([pseudo isEqualToString:@"lang:"]) continue;
        if ([pseudo hasPrefix:@"lang:"]) {
            NSString *want = [pseudo substringFromIndex:5];
            NSString *have = node.lang ?: @"";
            if (!([have isEqualToString:want] || [have hasPrefix:[want stringByAppendingString:@"-"]])) return NO;
            continue;
        }
        if ([pseudo hasPrefix:@"nth:"]) {
            if (!nthMatches([pseudo substringFromIndex:4], node.childIndex + 1)) return NO;
            continue;
        }
        if ([pseudo isEqualToString:@"first-child"]) {
            if (node.childIndex != 0) return NO;
            continue;
        }
        if ([pseudo isEqualToString:@"last-child"]) {
            if (!node.isLast) return NO;
            continue;
        }
        if ([pseudo isEqualToString:@"is"] || [pseudo isEqualToString:@"not"] || [pseudo isEqualToString:@"where"]) {
            NSArray<SGCCompound *> *group = c.nested.count > nestedAt ? c.nested[nestedAt] : nil;
            nestedAt++;
            if (!group) return NO;
            BOOL any = NO;
            for (SGCCompound *alternative in group)
                if (sequenceMatches(alternative, node)) { any = YES; break; }
            if ([pseudo isEqualToString:@"not"] ? any : !any) return NO;
            continue;
        }
        return NO;
    }
    return YES;
}

BOOL SGCRuleMatches(SGCRule *rule, SGCMatchNode *node) {
    return sequenceMatches(rule.selector, node);
}
