// The Visualizer's shader host (SGRShader.h): one Metal view filling the field, the chosen shader's
// fragment drawing every frame straight onto it.
//
// The frame handed to the shader (SGRShaderFrame in each source) carries the clock, the song's
// position and the sound: the spectrum and the waveform packed onto one 128x2 float texture (the row
// a shader reads decides which), the cover as a texture, and the shader's own last frame beside it
// for the ones that smear or echo. The sound comes off SGRSpectrum (SGRSpectrum.h), fed by the
// pipeline's last stage (SpectrumTap.x); the cover comes off the player's artwork, the way the hills
// get theirs.
//
// A shader that wants its previous frame draws into an offscreen target, which is then blitted to the
// screen and kept for the next frame; the others draw straight to the screen.
//
// The view runs its display link only while the player may animate -- in a window, Spotify in front,
// Low Power Mode and Reduce Motion letting it, the player's open or close done -- at most as often as
// the shader asks, and it fades in and out as one view the way the hills do.
//
// Threading: main thread only, except the sound read, which SGRSpectrum owns.
#import "SGRShader.h"
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "LyricsShaders/LyricsShaders.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/PlayerEvents.h"
#import "Player.h"
#import "SGRSpectrum.h"
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>
#import <simd/simd.h>

// The sound texture: 128 spectrum points on row 0, the 256 waveform samples folded onto row 1's 128
// texels, two a texel in red and green, which is the packing the shaders' own readers decode.
enum { kSpectrumPoints = 128, kWaveSamples = SGRSpectrumWaveSamples, kSoundWidth = kWaveSamples };

// A rise toward the treble, in dB a band, since music has less there: the hills' own tuning.
static const float kSpectrumTilt = 0.6f;

// One slot per param, 16 at the most, the manifest's order flattened across four float4s. A colour's
// three channels sit on the three floats its slot names. A lyrics style's frame is the same head plus
// the lyrics engine's tail, 1920 bytes all told; the buffer carries that much either way.
enum { kParamSlots = 16, kFrameBytes = 1920 };
// How many frames of the spectrum's leap a beat is judged against.
enum { kFluxHistory = 32 };

// The frame, laid out exactly as the struct every source compiles against: nothing padded that they
// did not pad, the two float2s landing 8-aligned behind the floats before them.
typedef struct {
    vector_float2 resolution;
    vector_float2 focus;
    float focusRadius;
    float time;
    float deltaTime;
    uint32_t frameIndex;
    float motion;
    float level;
    float bass;
    float mid;
    float treble;
    float beat;
    float beatCount;
    float bpm;
    float energy;
    float brightness;
    float position;
    float duration;
    float progress;
    float playing;
    float sinceTrackChange;
    float trackSeed;
    vector_float2 tilt;
    float clipReady;
    float textReady;
    vector_float4 textAspect;
    vector_float4 color0;
    vector_float4 color1;
    vector_float4 color2;
    vector_float4 accent;
    vector_float4 key[3];
    vector_float4 params[kParamSlots / 4];
} SGRShaderFrame;

_Static_assert(sizeof(SGRShaderFrame) == 304, "the frame must match the struct the shaders compile against");

// A hex colour, #rgb, #rrggbb or #rrggbbaa, over grey when it is not one.
static vector_float4 colorOf(id value) {
    NSString *hex = [value isKindOfClass:NSString.class] ? value : nil;
    if (hex.length < 3) return (vector_float4){0.5, 0.5, 0.5, 1};
    hex = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
    if (hex.length == 3) {
        NSMutableString *six = [NSMutableString string];
        for (NSUInteger i = 0; i < 3; i++) [six appendFormat:@"%c%c", [hex characterAtIndex:i], [hex characterAtIndex:i]];
        hex = six;
    }
    unsigned value6 = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&value6];
    if (hex.length == 8) value6 >>= 8;
    return (vector_float4){((value6 >> 16) & 0xff) / 255.0, ((value6 >> 8) & 0xff) / 255.0, (value6 & 0xff) / 255.0, 1};
}

static uint32_t seedOf(NSString *text) {
    if (!text.length) return 0;
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < text.length; i++) {
        hash ^= (uint32_t)[text characterAtIndex:i];
        hash *= 16777619u;
    }
    return hash;
}

// What the field and the Player page ask of a Visualizer view, the hills' surface and this one's
// alike (SGRShader.h declares the protocol and this class; PlayerVisualiser.m keeps one of each and
// shows the right one). The state-observer conformance is private.
@interface SGRShaderView () <SGPlayerStateObserver>
@end

@implementation SGRShaderView {
    SGRShaderInfo *_shader;
    // The pieces, built once the shader's source is in.
    CAMetalLayer *_layer;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLBuffer> _frameBuffer;
    id<MTLTexture> _sound, _cover, _targets[2];
    id<MTLSamplerState> _sampler;
    BOOL _usesPrevious, _usesLyrics, _usesText, _usesClip, _previousReady, _building, _ready;
    NSUInteger _targetAt;
    // The Canvas clip's frames, through the cache.
    CVMetalTextureCacheRef _clipCache;
    CVMetalTexture _clipTexture;
    // The lyrics' blur over everything, as the hills hold theirs.
    UIVisualEffectView *_lyricsBlur;
    UIViewPropertyAnimator *_lyricsBlurAnimator;
    BOOL _lyricsRequested;
    NSArray<UIColor *> *_paletteColors;
    // The frame's clock and the sound's read of it.
    CADisplayLink *_link;
    CFTimeInterval _last, _fresh, _trackChangedAt, _lastBeatAt;
    uint32_t _frameIndex, _trackSeed;
    float _peak, _beat, _motion, _beatCount, _bpm;
    float _previousBands[SGRSpectrumBands], _flux[kFluxHistory];
    NSUInteger _fluxAt;
    uint64_t _generation;
    NSUInteger _palette;
    BOOL _reading;
}

// The clip provider installed once for every view (PlayerMotion.x sets it at launch).
static CVPixelBufferRef _Nullable (^sg_clipProvider)(void);

void SGRShaderSetClipPixelBufferProvider(CVPixelBufferRef _Nullable (^ _Nullable provider)(void)) {
    sg_clipProvider = [provider copy];
}

// As PlayerMotion.x: what fades is the effect view's effect, never its alpha or an ancestor's.
static UIBlurEffect *blurEffect(void) {
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static UIViewPropertyAnimator *setBlurIntensity(UIVisualEffectView *view, UIViewPropertyAnimator *animator, CGFloat intensity) {
    intensity = MIN(1, MAX(0, intensity));
    if (animator && animator.state != UIViewAnimatingStateInactive) [animator stopAnimation:YES];
    view.effect = nil;
    if (intensity <= 0) return nil;
    __weak UIVisualEffectView *weakView = view;
    UIViewPropertyAnimator *fractional = [[UIViewPropertyAnimator alloc] initWithDuration:1
                                                                                    curve:UIViewAnimationCurveLinear
                                                                               animations:^{ weakView.effect = blurEffect(); }];
    [fractional startAnimation];
    [fractional pauseAnimation];
    fractional.fractionComplete = intensity;
    return fractional;
}

- (instancetype)initWithShader:(SGRShaderInfo *)shader {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _shader = shader;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    _peak = -60;
    _trackChangedAt = CACurrentMediaTime();
    _usesPrevious = [shader.uses containsObject:@"previous"];
    _usesLyrics = [shader.uses containsObject:@"lyrics"];
    _usesText = [shader.uses containsObject:@"text"];
    _usesClip = [shader.uses containsObject:@"clip"]; 
    _lyricsBlur = [[UIVisualEffectView alloc] initWithEffect:nil];
    _lyricsBlur.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_lyricsBlur];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      NSProcessInfoPowerStateDidChangeNotification, UIAccessibilityReduceMotionStatusDidChangeNotification]) {
        [center addObserver:self selector:@selector(updateMotionSoon) name:name object:nil];
    }
    [center addObserver:self selector:@selector(artworkChanged) name:SGRNowPlayingArtworkDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(updateBlurOpacity) name:SGRPlayerBlurOpacityDidChangeNotification object:nil];
    [self updateBlurOpacity];
    SGRObservePlayerTransition(self, ^(id owner) { [owner updateMotion]; }, ^(id owner) { [owner updateMotion]; });
    SGAddPlayerStateObserver(self);
    [self artworkChanged];
    [self loadShader];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_link invalidate];
    if (_usesLyrics || _usesText) SGRLyricsShaderSetVisible(NO);
    if (_clipCache) CFRelease(_clipCache);
}

- (SGRShaderInfo *)shader {
    return _shader;
}

#pragma mark - the pipeline

// The source comes in at once for a compiled-in shader and off the catalog for the rest, so the
// library is built when it lands and the view lays out again around it.
- (void)loadShader {
    if (_ready || _building) return;
    _building = YES;
    __weak SGRShaderView *weakSelf = self;
    SGRShaderLoadSource(_shader, ^(NSString *source) {
        SGRShaderView *view = weakSelf;
        if (!view) return;
        view->_building = NO;
        if ([view buildWithSource:source]) {
            [view setNeedsLayout];
            [view updateMotion];
        }
    });
}

- (BOOL)buildWithSource:(NSString *)source {
    if (!source.length) return NO;
    if (!_device) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) return NO;
        _queue = [_device newCommandQueue];
        if (!_queue) return NO;
        _layer = [CAMetalLayer layer];
        _layer.device = _device;
        _layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _layer.opaque = YES;
        _layer.backgroundColor = UIColor.blackColor.CGColor;
        // The feedback targets are blitted to the screen, so the layer must take it.
        _layer.framebufferOnly = NO;
        [self.layer addSublayer:_layer];
    }
    // The catalog's shaders name their entry points and types with a house prefix of their own; the
    // renderer answers to one spelling only, this tree's, so the source is renamed as it comes in.
    // The prefix is assembled rather than spelled, so the search itself carries none of it.
    NSString *lower = [NSString stringWithFormat:@"ch%@a", @"rom"];
    NSString *upper = [NSString stringWithFormat:@"Ch%@a", @"rom"];
    NSArray<NSArray<NSString *> *> *renames = @[
        @[[NSString stringWithFormat:@"\\b%@(\\w*)\\b", lower], @"sgShader$1"],
        @[[NSString stringWithFormat:@"\\b%@(\\w*)\\b", upper], @"SGRShader$1"],
    ];
    for (NSArray<NSString *> *rename in renames) {
        NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:rename[0] options:0 error:nil];
        source = [expression stringByReplacingMatchesInString:source options:0
                                                        range:NSMakeRange(0, source.length)
                                                 withTemplate:rename[1]];
    }
    NSError *error = nil;
    {
        id<MTLLibrary> library = [_device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            SGLog(@"redesign visualizer: %@ did not compile (%@)", _shader.name, error.localizedDescription);
            return NO;
        }
        id<MTLFunction> vertex = [library newFunctionWithName:@"sgShaderVertex"];
        id<MTLFunction> fragment = [library newFunctionWithName:@"sgShaderFragment"];
        if (!vertex || !fragment) {
            SGLog(@"redesign visualizer: %@ carries no entry points", _shader.name);
            return NO;
        }
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = vertex;
        descriptor.fragmentFunction = fragment;
        descriptor.colorAttachments[0].pixelFormat = _layer.pixelFormat;
        id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!pipeline) {
            SGLog(@"redesign visualizer: %@'s pipeline did not build (%@)", _shader.name, error.localizedDescription);
            return NO;
        }
        _pipeline = pipeline;
        _frameBuffer = [_device newBufferWithLength:kFrameBytes options:MTLResourceStorageModeShared];
    }
    MTLTextureDescriptor *sound = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                     width:kSoundWidth height:2 mipmapped:NO];
    sound.usage = MTLTextureUsageShaderRead;
    sound.storageMode = MTLStorageModeShared;
    _sound = [_device newTextureWithDescriptor:sound];
    for (int side = 0; side < 2; side++) _targets[side] = [self newTargetWidth:2 height:2];
    if (_usesClip) {
        CVReturn made = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, _device, nil, &_clipCache);
        if (made != kCVReturnSuccess) {
            _usesClip = NO;
            SGLog(@"redesign visualizer: the clip cache did not build (%d)", (int)made);
        }
    }
    // Poster and Cut are the only player shaders that use the Lyrics engine. Downloadable
    // lyrics-shaders never enter this player host.
    if (_usesLyrics || _usesText) {
        SGRLyricsShaderUseDevice(_device, _queue);
        SGRLyricsShaderSetStyle(_shader.identifier);
        SGRLyricsShaderSetVisible(YES);
    }
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.minFilter = MTLSamplerMinMagFilterLinear;
    sampler.magFilter = MTLSamplerMinMagFilterLinear;
    sampler.sAddressMode = MTLSamplerAddressModeClampToEdge;
    sampler.tAddressMode = MTLSamplerAddressModeClampToEdge;
    _sampler = [_device newSamplerStateWithDescriptor:sampler];
    _ready = YES;
    [self paintCover];
    SGLog(@"redesign visualizer: %@ on the field", _shader.name);
    return YES;
}

- (id<MTLTexture>)newTargetWidth:(NSUInteger)width height:(NSUInteger)height {
    MTLTextureDescriptor *color = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_layer.pixelFormat
                                                                                     width:width height:height mipmapped:NO];
    color.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    color.storageMode = MTLStorageModePrivate;
    return [_device newTextureWithDescriptor:color];
}

- (void)resizeTargets {
    CGSize size = self.bounds.size;
    CGFloat scale = UIScreen.mainScreen.scale;
    _layer.contentsScale = scale;
    // The shader renders at a share of the screen it asks for, never past it, never under a few
    // pixels a side.
    CGFloat shaderScale = MIN(1, MAX(0.25, _shader.scale));
    CGSize screen = UIScreen.mainScreen.bounds.size;
    CGSize pixels = CGSizeMake(MIN(MAX(round(size.width * scale * shaderScale), 2), round(screen.width * scale)),
                               MIN(MAX(round(size.height * scale * shaderScale), 2), round(screen.height * scale)));
    if (!CGSizeEqualToSize(_layer.drawableSize, pixels)) {
        _layer.drawableSize = pixels;
        for (int side = 0; side < 2; side++) _targets[side] = [self newTargetWidth:pixels.width height:pixels.height];
        _previousReady = NO;
    }
}

#pragma mark - the cover

- (void)artworkChanged {
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;
    NSUInteger generation = ++_palette;
    SGRPaletteRequest request = {CGSizeZero, NO, YES, YES, NO};
    __weak SGRShaderView *weakSelf = self;
    [SGRPalette paletteForImage:image request:request completion:^(SGRPalette *palette) {
        SGRShaderView *view = weakSelf;
        if (!view || generation != view->_palette) return;
        view->_paletteColors = palette.flowColors ?: @[];
    }];
    [self paintCover];
}

// The cover as a texture, no bigger than 512 a side, which is past what any shader samples it at.
- (void)paintCover {
    if (!_device) return;
    UIImage *image = SGRNowPlayingArtwork(NULL, NULL);
    if (!image) return;
    CGImageRef cg = image.CGImage;
    if (!cg) return;
    NSUInteger width = MIN(CGImageGetWidth(cg), 512), height = MIN(CGImageGetHeight(cg), 512);
    if (!width || !height) return;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [_device newTextureWithDescriptor:descriptor];
    if (!texture) return;
    NSUInteger bytesPerRow = 4 * width;
    void *pixels = malloc(bytesPerRow * height);
    if (!pixels) return;
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, bytesPerRow,
                                                 CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), cg);
        CGContextRelease(context);
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:pixels bytesPerRow:bytesPerRow];
        _cover = texture;
    }
    free(pixels);
}

#pragma mark - the frame

// The colours: three of the cover's for the shader to blend by, the accent over them, and the twelve
// numbers of the key carrying the same three again for the shaders that count along them.
- (void)paintColoursInto:(SGRShaderFrame *)frame {
    CGFloat red, green, blue, alpha;
    UIColor *zero = _paletteColors.count >= 5 ? _paletteColors[0] : UIColor.darkGrayColor;
    UIColor *one = _paletteColors.count >= 5 ? _paletteColors[2] : UIColor.darkGrayColor;
    UIColor *two = _paletteColors.count >= 5 ? _paletteColors[4] : UIColor.darkGrayColor;
    [zero getRed:&red green:&green blue:&blue alpha:&alpha];
    frame->color0 = (vector_float4){(float)red, (float)green, (float)blue, (float)alpha};
    [one getRed:&red green:&green blue:&blue alpha:&alpha];
    frame->color1 = (vector_float4){(float)red, (float)green, (float)blue, (float)alpha};
    [two getRed:&red green:&green blue:&blue alpha:&alpha];
    frame->color2 = (vector_float4){(float)red, (float)green, (float)blue, (float)alpha};
    // The redesign's accent, the mod's own green while none is picked: either way the shaders get one.
    UIColor *accent = SGRAccentColor() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1];
    [accent getRed:&red green:&green blue:&blue alpha:&alpha];
    frame->accent = (vector_float4){(float)red, (float)green, (float)blue, (float)alpha};
    vector_float4 key[3] = {frame->color0, frame->color1, frame->color2};
    memcpy(frame->key, key, sizeof key);
}

- (SGRShaderFrame)nextFrame:(double)deltaTime {
    SGRShaderFrame frame;
    memset(&frame, 0, sizeof frame);
    CGSize pixels = _layer.drawableSize;
    frame.resolution = (vector_float2){(float)pixels.width, (float)pixels.height};
    frame.focus = (vector_float2){0.5, 0.5};
    frame.focusRadius = 1.0;
    frame.time = (float)CACurrentMediaTime();
    frame.deltaTime = (float)deltaTime;
    frame.frameIndex = _frameIndex;
    frame.position = (float)SGPlayerState().position;
    frame.duration = (float)SGPlayerState().duration;
    frame.progress = frame.duration > 0 ? frame.position / frame.duration : 0;
    frame.playing = SGPlayerState().isPaused ? 0 : 1;
    frame.sinceTrackChange = (float)(CACurrentMediaTime() - _trackChangedAt);
    frame.trackSeed = _trackSeed;
    frame.textAspect = (vector_float4){1, 1, 1, 1};
    [self paintColoursInto:&frame];
    // The user's values for the shader's params, a float4 row at a time; a colour sits on the three
    // floats its slot names, a toggle and a float on the one float of theirs. The lyrics styles keep
    // theirs in the lyrics engine's store.
    NSDictionary<NSString *, id> *values = [_shader.identifier hasPrefix:@"builtin:poster"]
        || [_shader.identifier hasPrefix:@"builtin:cut"]
        ? SGRLyricsShaderParamValues(_shader.identifier)
        : SGRShaderParamValues(_shader);
    float slots[kParamSlots] = {0};
    for (NSDictionary *param in _shader.params) {
        if (![param isKindOfClass:NSDictionary.class]) continue;
        NSInteger slot = [param[@"slot"] isKindOfClass:NSNumber.class] ? [param[@"slot"] integerValue] : -1;
        if (slot < 0 || slot >= kParamSlots) continue;
        NSString *type = [param[@"type"] isKindOfClass:NSString.class] ? param[@"type"] : @"float";
        id value = values[param[@"id"]];
        if ([type isEqualToString:@"color"]) {
            vector_float4 colour = colorOf(value);
            for (NSInteger channel = 0; channel < 3 && slot + channel < kParamSlots; channel++) slots[slot + channel] = colour[channel];
        } else if ([type isEqualToString:@"toggle"]) {
            slots[slot] = [value boolValue] ? 1 : 0;
        } else {
            slots[slot] = (float)[value doubleValue];
        }
    }
    for (NSInteger row = 0; row < kParamSlots / 4; row++)
        frame.params[row] = (vector_float4){slots[row * 4], slots[row * 4 + 1], slots[row * 4 + 2], slots[row * 4 + 3]};
    return frame;
}

#pragma mark - the sound

// The 24 bands stretched over the texture's 128 points, each point reading the band its share of the
// way along, against a share of the song's own loudness exactly as the hills take theirs.
- (void)fillSound:(SGRShaderFrame *)frame deltaTime:(double)deltaTime now:(CFTimeInterval)now {
    float levels[SGRSpectrumBands];
    uint64_t generation = SGRSpectrumRead(levels);
    if (generation != _generation) {
        _generation = generation;
        _fresh = now;
    }
    BOOL silent = !_reading || now - _fresh > 0.3;
    if (!silent) {
        float loudest = -100;
        for (NSInteger band = 0; band < SGRSpectrumBands; band++) loudest = MAX(loudest, levels[band] + kSpectrumTilt * band);
        _peak = MAX(MAX(loudest, _peak - 4 * (float)deltaTime), -60);
    }
    float values[kSpectrumPoints];
    for (int point = 0; point < kSpectrumPoints; point++) {
        CGFloat along = (CGFloat)point / (kSpectrumPoints - 1);
        CGFloat at = along * (SGRSpectrumBands - 1);
        NSInteger band = (NSInteger)at;
        CGFloat into = at - band;
        float level = levels[band] * (1 - into) + levels[MIN(band + 1, SGRSpectrumBands - 1)] * into;
        float tilted = level + kSpectrumTilt * (float)point / (kSpectrumPoints - 1) * 3;
        values[point] = silent ? 0 : MIN(1, MAX(0, (tilted - (_peak - 40)) / 40));
    }
    [self watchBeat:values silent:silent deltaTime:deltaTime now:now];

    float wave[kWaveSamples];
    SGRSpectrumWave(wave);
    float sound[kSoundWidth * 2 * 4] = {0};
    for (int x = 0; x < kSoundWidth; x++) {
        float *spectrum = sound + x * 4, *waveform = sound + (kSoundWidth + x) * 4;
        if (x < kSpectrumPoints) spectrum[0] = values[x];
        waveform[0] = wave[x];
    }
    [_sound replaceRegion:MTLRegionMake2D(0, 0, kSoundWidth, 2) mipmapLevel:0 withBytes:sound bytesPerRow:kSoundWidth * 4 * 4];

    // The frame's own handful of numbers off the same points: three bands of the song's height.
    float sum = 0, low = 0, middle = 0, high = 0;
    for (int point = 0; point < kSpectrumPoints; point++) {
        sum += values[point];
        if (point < kSpectrumPoints / 3) low += values[point];
        else if (point < 2 * kSpectrumPoints / 3) middle += values[point];
        else high += values[point];
    }
    frame->level = sum / kSpectrumPoints;
    frame->bass = low / (kSpectrumPoints / 3);
    frame->mid = middle / (kSpectrumPoints / 3);
    frame->treble = high / (kSpectrumPoints - 2 * kSpectrumPoints / 3);
    frame->beat = _beat;
    frame->beatCount = _beatCount;
    frame->bpm = _bpm;
    frame->energy = frame->level;
    frame->brightness = frame->treble;
    frame->motion = _motion;
}


// A leap in the spectrum over the frames just before it is a beat: it pushes the beat's envelope to
// one and the count on, keeps a rough tempo, and the motion eases back down between beats.
- (void)watchBeat:(const float *)values silent:(BOOL)silent deltaTime:(double)deltaTime now:(CFTimeInterval)now {
    float flux = 0;
    if (!silent) {
        for (NSInteger band = 0; band < SGRSpectrumBands; band++) {
            NSInteger point = (NSInteger)((CGFloat)band / (SGRSpectrumBands - 1) * (kSpectrumPoints - 1));
            float rise = values[point] - _previousBands[band];
            _previousBands[band] = values[point];
            flux += rise > 0 ? rise : 0;
        }
        flux /= SGRSpectrumBands;
        _flux[_fluxAt % kFluxHistory] = flux;
        _fluxAt++;
        NSInteger held = MIN((NSInteger)_fluxAt, (NSInteger)kFluxHistory);
        float mean = 0;
        for (NSInteger i = 0; i < held; i++) mean += _flux[i];
        mean /= held;
        if (flux > mean * 1.6f && flux > 0.04f && now - _lastBeatAt > 0.22) {
            if (_lastBeatAt > 0) {
                double interval = now - _lastBeatAt;
                if (interval > 0.25 && interval < 1.5) _bpm = _bpm ? _bpm * 0.8f + (float)(60.0 / interval) * 0.2f : (float)(60.0 / interval);
            }
            _lastBeatAt = now;
            _beat = 1;
            _beatCount += 1;
            _motion = 1;
        }
    }
    _beat = MAX(0, _beat - (float)(deltaTime / 0.18));
    _motion = MAX(0, _motion - (float)(deltaTime / 1.2));
}

#pragma mark - drawing

- (void)tick:(CADisplayLink *)link {
    if (!_ready) return;
    CFTimeInterval now = link.timestamp;
    double dt = _last ? MIN(now - _last, 0.1) : link.duration;
    _last = now;
    _frameIndex++;

    id<CAMetalDrawable> drawable = [_layer nextDrawable];
    if (!drawable) return;
    if (_usesLyrics || _usesText) SGRLyricsShaderUpdate();
    SGRShaderFrame frame = [self nextFrame:dt];
    [self fillSound:&frame deltaTime:dt now:now];
    [self fillFeeds:&frame];
    [self paintFrame:&frame drawable:drawable];
}

// The clip's frame now and the lyrics' readiness, into the frame's head. The clip pixel buffer is
// pulled here and bound in the pass that follows; the lyrics engine was pumped before this ran.
- (void)fillFeeds:(SGRShaderFrame *)frame {
    if (_usesClip && sg_clipProvider) {
        CVPixelBufferRef pixel = sg_clipProvider();
        if (pixel) {
            CVReturn made = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, _clipCache, pixel, nil,
                                                                      MTLPixelFormatBGRA8Unorm, 0, 0, 0, &_clipTexture);
            frame->clipReady = made == kCVReturnSuccess ? 1 : 0;
            CVPixelBufferRelease(pixel);
            if (made != kCVReturnSuccess && _clipTexture) { CFRelease(_clipTexture); _clipTexture = nil; }
        } else {
            frame->clipReady = 0;
        }
    }
    if (_usesText) {
        frame->textReady = SGRLyricsShaderTextReady() ? 1 : 0;
        if (frame->textReady) {
            float aspect[4];
            SGRLyricsShaderTextAspect(aspect);
            frame->textAspect = (vector_float4){aspect[0], aspect[1], aspect[2], aspect[3]};
        }
    }
}

// One pass: into the screen for most shaders, into the other offscreen target for the ones that read
// their last frame, which is then blitted to the screen and kept for the next. A device too busy to
// hand a frame is skipped; the next frame's link tick comes round soon enough.
- (void)paintFrame:(SGRShaderFrame *)frame drawable:(id<CAMetalDrawable>)drawable {
    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    if (!buffer) return;
    id<MTLTexture> made = drawable.texture;
    if (_usesPrevious) {
        _targetAt = 1 - _targetAt;
        made = _targets[_targetAt];
    }

    memcpy(_frameBuffer.contents, frame, sizeof *frame);
    if (_usesLyrics || _usesText) SGRLyricsShaderFillStyleFrame(_frameBuffer.contents, kFrameBytes);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = made;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    [encoder setRenderPipelineState:_pipeline];
    [encoder setFragmentBuffer:_frameBuffer offset:0 atIndex:0];
    [encoder setFragmentTexture:_cover ?: _sound atIndex:0];
    [encoder setFragmentTexture:(_usesClip && _clipTexture) ? CVMetalTextureGetTexture(_clipTexture) : (_cover ?: _sound) atIndex:1];
    [encoder setFragmentTexture:(_usesText && frame->textReady) ? SGRLyricsShaderTextTexture() : _sound atIndex:2];
    [encoder setFragmentTexture:_sound atIndex:3];
    [encoder setFragmentTexture:_previousReady ? _targets[1 - _targetAt] : _sound atIndex:4];
    [encoder setFragmentTexture:_usesLyrics ? SGRLyricsShaderLyricsTexture() : _sound atIndex:5];
    [encoder setFragmentSamplerState:_sampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    if (made != drawable.texture) {
        id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
        [blit copyFromTexture:made toTexture:drawable.texture];
        [blit endEncoding];
    }
    [buffer presentDrawable:drawable];
    [buffer commit];
    if (_usesPrevious) _previousReady = YES;
    if (_clipTexture) { CFRelease(_clipTexture); _clipTexture = nil; }
}

#pragma mark - showing

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    _lyricsBlur.frame = bounds;
    _layer.frame = bounds;
    if (_ready) [self resizeTargets];
}

- (void)appear:(BOOL)animated {
    self.alpha = 0;
    if (animated) SGRAnimate(SGRMotionFade, ^{ self.alpha = 1; }, nil);
    else self.alpha = 1;
}

- (void)disappear:(void (^)(void))done {
    if (_usesLyrics || _usesText) SGRLyricsShaderSetVisible(NO);
    SGRAnimate(SGRMotionFade, ^{
        self.alpha = 0;
        self->_lyricsRequested = NO;
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, 0);
    }, ^(BOOL finished) { done(); });
}

- (BOOL)blurred {
    return _lyricsRequested;
}

- (void)setBlurred:(BOOL)blurred animated:(BOOL)animated {
    _lyricsRequested = blurred;
    CGFloat opacity = MIN(100, MAX(0, SGInt(SGRKeyPlayerVisualiserBlurOpacity, 100))) / 100.0;
    void (^apply)(void) = ^{
        self->_lyricsBlurAnimator = setBlurIntensity(self->_lyricsBlur, self->_lyricsBlurAnimator, blurred ? opacity : 0);
    };
    if (animated) SGRAnimate(SGRMotionFade, apply, nil);
    else apply();
    [self updateMotion];
}

- (void)updateBlurOpacity {
    CGFloat opacity = MIN(100, MAX(0, SGInt(SGRKeyPlayerVisualiserBlurOpacity, 100))) / 100.0;
    _lyricsBlurAnimator = setBlurIntensity(_lyricsBlur, _lyricsBlurAnimator, _lyricsRequested ? opacity : 0);
}

// A new track: the seed the shaders stir themselves with moves and the clock since the change starts
// over, so an intro and a drop can look different under the same shader.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    uint32_t seed = seedOf(SGURIString(state.track.URI));
    if (seed != _trackSeed) {
        _trackSeed = seed;
        _trackChangedAt = CACurrentMediaTime();
        if (SGEnabled(SGRKeyVisualiserShuffle)) {
            NSArray<SGRShaderInfo *> *shaders = SGRShaders();
            if (shaders.count > 1) {
                NSMutableArray *others = [shaders mutableCopy];
                [others removeObject:SGRShaderChosen()];
                SGRShaderChoose(others[(NSUInteger)arc4random_uniform((u_int32_t)others.count)]);
            }
        }
    }
    [self updateMotion];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && (_usesLyrics || _usesText) && _ready) SGRLyricsShaderSetVisible(YES);
    else if (!self.window && (_usesLyrics || _usesText)) SGRLyricsShaderSetVisible(NO);
    [self updateMotion];
    [self loadShader];
}

// The power state is reported off the main thread.
- (void)updateMotionSoon {
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateMotion]; });
}

// Moving while it may: the same conditions the hills keep (PlayerVisualiser.m), at the shader's own
// pace, down to a slow watch while nothing plays so a stall is noticed.
- (void)updateMotion {
    BOOL front = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    BOOL may = self.window && front && !NSProcessInfo.processInfo.lowPowerModeEnabled && self.alpha > 0;
    NSTimeInterval wait = SGPlayerTransitionEnds() - CACurrentMediaTime();
    if (may && (wait > 0 || SGRPlayerIsTransitioning())) {
        may = NO;
        // Without an expected end, the transition's ended notification brings it back.
        if (wait > 0) [self performSelector:@selector(updateMotion) withObject:nil afterDelay:wait + 0.05 inModes:@[NSRunLoopCommonModes]];
    }
    BOOL playing = !SGPlayerState().isPaused;
    BOOL moving = may && playing;
    [self setReading:moving];
    if (moving) {
        if (!_link) {
            _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
            [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
            _last = 0;
        }
        NSInteger most = _shader.fps == 120 ? 120 : _shader.fps == 30 ? 30 : 60;
        if (SGRReduceMotion()) most = MIN(most, (NSInteger)15);
        else if (_lyricsRequested) most = MIN(most, (NSInteger)60);
        _link.preferredFrameRateRange = CAFrameRateRangeMake(most / 2.0, most, most);
    } else if (_link) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)setReading:(BOOL)reading {
    if (reading == _reading) return;
    _reading = reading;
    SGRSpectrumSetWanted(reading);
}

@end
