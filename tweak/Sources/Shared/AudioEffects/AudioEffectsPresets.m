// The presets: built-in ones over a reset, and the user's own as a copy of every dsp key. Everything goes back
// in through AudioEffects.h's setters, so it is clamped and applied the way the page's own changes are.
// The built-ins and the community presets (AudioEffectsCommunity.m) are written in the same upstream keys
// and come through SGDSPLoadPresetSettings together.
#import "AudioEffects.h"
#import "AudioEffectsApply.h"
#import "AudioEffectsPresets.h"

static NSString *const kPrefix = @"spotifyglass.dsp.";

static NSUserDefaults *store(void) {
    return NSUserDefaults.standardUserDefaults;
}

// A value back through its setter: a switch (the key naming its own effect), a number, the gains as a
// list, or text. Anything else is left out, a preset from a later build naming a key this one lacks too.
static void setValue(NSString *key, id value) {
    if (![key hasPrefix:kPrefix]) return;
    if ([value isKindOfClass:NSArray.class]) SGDSPSetGains(key, value);
    else if ([value isKindOfClass:NSString.class]) SGDSPSetString(key, value);
    else if (![value isKindOfClass:NSNumber.class]) return;
    else if ([SGDSPEffectOf(key) isEqualToString:key]) SGDSPSetSwitch(key, [value boolValue]);
    else SGDSPSetNumber(key, [value doubleValue]);
}

// A pick is meant to be heard: the master switch, off until asked for, comes on with it.
static void turnOn(void) {
    if (!SGDSPSwitch(SGKeyDSP)) SGDSPSetSwitch(SGKeyDSP, YES);
}

static NSDictionary<NSString *, id> *currentValues(void) {
    NSDictionary<NSString *, id> *all = store().dictionaryRepresentation;
    NSMutableDictionary<NSString *, id> *values = [NSMutableDictionary dictionary];
    for (NSString *key in all) {
        if ([key hasPrefix:kPrefix]) values[key] = all[key];
    }
    return values;
}

#pragma mark - the upstream settings

// The gains as the setter takes them, from a "g;g;..." line: an unreadable band reads as 0, and the
// setter clamps every band and fills the rest up. An empty part stays a band, so a stray ';' never shifts
// the rest over. A list the server sent as numbers goes in as it is.
static void setGains(NSString *key, id value) {
    if ([value isKindOfClass:NSArray.class]) {
        SGDSPSetGains(key, value);
        return;
    }
    if (![value isKindOfClass:NSString.class]) return;
    NSMutableArray<NSNumber *> *gains = [NSMutableArray array];
    for (NSString *part in [value componentsSeparatedByString:@";"]) [gains addObject:@(part.doubleValue)];
    SGDSPSetGains(key, gains);
}

// One upstream setting into its dsp key. Anything the mod has no answer for is left out. The file keys
// (convolver.file and its friends) are not set here: they name files by their checksum, and
// AudioEffectsCommunity.m lands those in the libraries first and sets the keys itself.
static void applySetting(NSString *setting, id value) {
    BOOL gains = [setting isEqualToString:@"eq.gains"] || [setting isEqualToString:@"compander.gains"];
    if ([value isKindOfClass:NSDictionary.class] || (!gains && [value isKindOfClass:NSArray.class])) return;
    NSString *key = nil;
    if ([setting isEqualToString:@"eq"]) key = SGKeyDSPEqualizer;
    else if ([setting isEqualToString:@"bass"]) key = SGKeyDSPBass;
    else if ([setting isEqualToString:@"wide"]) key = SGKeyDSPStereoWide;
    else if ([setting isEqualToString:@"reverb"]) key = SGKeyDSPReverb;
    else if ([setting isEqualToString:@"tube"]) key = SGKeyDSPTube;
    else if ([setting isEqualToString:@"compander"]) key = SGKeyDSPCompander;
    else if ([setting isEqualToString:@"crossfeed"]) key = SGKeyDSPCrossfeed;
    else if ([setting isEqualToString:@"geq"]) key = SGKeyDSPGraphicEq;
    else if ([setting isEqualToString:@"convolver"]) key = SGKeyDSPConvolver;
    else if ([setting isEqualToString:@"ddc"]) key = SGKeyDSPDDC;
    else if ([setting isEqualToString:@"liveprog"]) key = SGKeyDSPLiveprog;
    if (key) {
        SGDSPSetSwitch(key, [value boolValue]);
        return;
    }
    if ([setting isEqualToString:@"eq.gains"]) setGains(SGKeyDSPEqualizerGains, value);
    else if ([setting isEqualToString:@"compander.gains"]) setGains(SGKeyDSPCompanderGains, value);
    else if ([setting isEqualToString:@"geq.nodes"]) {
        NSString *line = SGDSPGraphicEqLine([value isKindOfClass:NSString.class] ? value : nil);
        if (line.length) SGDSPSetString(SGKeyDSPGraphicEqNodes, line);
    }
    else if ([setting isEqualToString:@"bass.gain"]) SGDSPSetNumber(SGKeyDSPBassGain, [value doubleValue]);
    else if ([setting isEqualToString:@"wide.level"]) SGDSPSetNumber(SGKeyDSPStereoWideLevel, [value doubleValue]);
    else if ([setting isEqualToString:@"reverb.preset"]) SGDSPSetNumber(SGKeyDSPReverbPreset, [value doubleValue]);
    else if ([setting isEqualToString:@"reverb.amount"]) SGDSPSetReverbAmount([value doubleValue]);
    else if ([setting isEqualToString:@"tube.drive"]) SGDSPSetNumber(SGKeyDSPTubeDrive, [value doubleValue]);
    else if ([setting isEqualToString:@"compander.time"]) SGDSPSetNumber(SGKeyDSPCompanderTime, [value doubleValue]);
    else if ([setting isEqualToString:@"crossfeed.mode"]) SGDSPSetNumber(SGKeyDSPCrossfeedMode, [value doubleValue]);
    else if ([setting isEqualToString:@"convolver.mode"]) SGDSPSetNumber(SGKeyDSPConvolverMode, [value doubleValue]);
    else if ([setting isEqualToString:@"postGain"]) SGDSPSetNumber(SGKeyDSPPostGain, [value doubleValue]);
    else if ([setting isEqualToString:@"limiterThreshold"]) SGDSPSetNumber(SGKeyDSPLimiterThreshold, [value doubleValue]);
    else if ([setting isEqualToString:@"limiterRelease"]) SGDSPSetNumber(SGKeyDSPLimiterRelease, [value doubleValue]);
    // Crossfeed has no level of its own, only its three modes strongest first, so a level picks one by thirds.
    else if ([setting isEqualToString:@"crossfeed.level"])
        SGDSPSetNumber(SGKeyDSPCrossfeedMode, [value doubleValue] < 34 ? 0 : [value doubleValue] < 67 ? 1 : 2);
}

// The door every set of preset settings comes through: the Graphic EQ kept, everything else reset, then
// the settings in through the setters, and the master switch on so the pick is heard.
void SGDSPLoadPresetSettings(NSDictionary<NSString *, id> *settings) {
    if (!settings.count) return;
    NSMutableDictionary<NSString *, id> *kept = [NSMutableDictionary dictionary];
    NSDictionary<NSString *, id> *now = currentValues();
    for (NSString *key in now) {
        if ([SGDSPEffectOf(key) isEqualToString:SGKeyDSPGraphicEq]) kept[key] = now[key];
    }
    SGDSPResetAll();
    for (NSString *key in kept) setValue(key, kept[key]);
    for (NSString *key in settings) applySetting(key, settings[key]);
    turnOn();
}

#pragma mark - built in

typedef struct {
    NSString *__unsafe_unretained name, *__unsafe_unretained category, *__unsafe_unretained detail;
} SGDSPPresetName;

static const SGDSPPresetName kBuiltIn[] = {
    {@"Bass boost", @"Sound", @"More low end, held back when it gets loud"},
    {@"Vocal", @"Sound", @"Voices forward and steadier"},
    {@"Clarity", @"Sound", @"Crisper highs, less boom"},
    {@"Warm", @"Sound", @"Softer highs and tube warmth"},
    {@"Punchy", @"Sound", @"Harder kicks and snares"},
    {@"Headphones", @"Listening", @"Softer stereo for long listening"},
};

// The same upstream keys the community presets speak, so everything goes through the one door.
static NSDictionary<NSString *, id> *builtInValues(NSInteger index) {
    switch (index) {
        case 0: return @{@"bass": @YES, @"bass.gain": @8};
        case 1: return @{@"eq": @YES, @"eq.gains": @"-2;-2;-2;-1;-1;0;1;2;3;3;2;1;0;-1;-1",
                         @"compander": @YES, @"compander.gains": @"0;0;0.3;0.4;0.4;0.2;0"};
        case 2: return @{@"eq": @YES, @"eq.gains": @"0;0;0;-1;-1;-1;0;0;0;1;2;3;3;3;2"};
        case 3: return @{@"eq": @YES, @"tube": @YES, @"eq.gains": @"2;2;2;2;1;1;0;0;0;-1;-1;-2;-2;-2;-2", @"tube.drive": @5};
        case 4: return @{@"eq": @YES, @"eq.gains": @"3;3;2;1;0;-1;-1;0;0;1;1;1;1;0;0",
                         @"compander": @YES, @"compander.time": @0.1,
                         @"compander.gains": @"-0.5;-0.3;0;0;-0.3;-0.2;0", @"limiterThreshold": @-0.5};
        case 5: return @{@"eq": @YES, @"eq.gains": @"1;1;1;0;0;0;0;0;0;0;-1;-1;-1;0;0",
                         @"crossfeed": @YES, @"crossfeed.level": @60};
    }
    return nil;
}

NSArray<NSString *> *SGDSPBuiltInPresetNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kBuiltIn / sizeof *kBuiltIn; i++) [names addObject:kBuiltIn[i].name];
    return names;
}

NSString *SGDSPBuiltInPresetCategory(NSInteger index) {
    return index >= 0 && index < (NSInteger)(sizeof kBuiltIn / sizeof *kBuiltIn) ? kBuiltIn[index].category : nil;
}

NSString *SGDSPBuiltInPresetDetail(NSInteger index) {
    return index >= 0 && index < (NSInteger)(sizeof kBuiltIn / sizeof *kBuiltIn) ? kBuiltIn[index].detail : nil;
}

void SGDSPLoadBuiltInPreset(NSInteger index) {
    NSDictionary<NSString *, id> *values = builtInValues(index);
    if (!values) return;
    SGDSPLoadPresetSettings(values);
}

#pragma mark - the user's

static NSDictionary<NSString *, NSDictionary *> *userPresets(void) {
    id presets = [store() objectForKey:SGKeyDSPUserPresets];
    return [presets isKindOfClass:NSDictionary.class] ? presets : @{};
}

NSArray<NSString *> *SGDSPUserPresetNames(void) {
    return [userPresets().allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

void SGDSPSaveUserPreset(NSString *name) {
    if (!name.length) return;
    NSMutableDictionary *presets = [userPresets() mutableCopy];
    presets[name] = currentValues();
    [store() setObject:presets forKey:SGKeyDSPUserPresets];
}

BOOL SGDSPLoadUserPreset(NSString *name) {
    NSDictionary *values = userPresets()[name];
    if (![values isKindOfClass:NSDictionary.class]) return NO;
    SGDSPResetAll();
    for (NSString *key in values) setValue(key, values[key]);
    turnOn();
    return YES;
}

void SGDSPDeleteUserPreset(NSString *name) {
    NSMutableDictionary *presets = [userPresets() mutableCopy];
    [presets removeObjectForKey:name];
    [store() setObject:presets forKey:SGKeyDSPUserPresets];
}

#pragma mark - GraphicEQ text

// One line: AutoEq's files end in a newline, and a copy out of a web page often has more.
NSString *SGDSPGraphicEqLine(NSString *text) {
    NSArray<NSString *> *words = [text ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    words = [words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    NSString *line = [words componentsJoinedByString:@" "];
    return [line.lowercaseString hasPrefix:@"graphiceq:"] ? line : nil;
}
