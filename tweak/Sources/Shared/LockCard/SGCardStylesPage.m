// The styles page: the preview header renders the chosen style with the sample data at the
// card's aspect, then a row per builtin and catalog style -- the value carries the tick, a tap
// chooses and re-renders -- then the refresh row. Not wired anywhere: the integrator adds
// SGPageRow(@"Lock screen card", ^{ return SGLockCardStylesPage(); }) to its page.
#import "SGCardEngine.h"
#import "Core/SGCore.h"
#import "Shared/Catalog/SGCatalog.h"
#import "Settings/SGModPage.h"

// The preview at the top: the engine's own render of the sample data, redrawn when the style
// changes or the catalog lands.
@interface SGCardPreview : UIView
- (CGSize)heightForWidth:(CGFloat)width;
- (void)reload;
@end

@implementation SGCardPreview {
    UIImageView *_image;
    UILabel *_caption;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    _image = [UIImageView new];
    _image.contentMode = UIViewContentModeScaleAspectFit;
    _image.layer.cornerRadius = 18;
    _image.layer.masksToBounds = YES;
    _image.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    _image.layer.borderWidth = 1;
    [self addSubview:_image];
    _caption = [UILabel new];
    _caption.font = [UIFont systemFontOfSize:12];
    _caption.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    _caption.textAlignment = NSTextAlignmentCenter;
    [self addSubview:_caption];
    return self;
}

- (CGSize)heightForWidth:(CGFloat)width {
    CGFloat imageHeight = width * 0.82;
    return imageHeight + 26;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width;
    CGFloat imageHeight = width * 0.82;
    // the card at its own aspect, fitted into the preview's height
    CGFloat aspect = 393.0 / 852.0;
    CGFloat height = MIN(imageHeight, width / aspect * 0.9);
    CGFloat cardWidth = height * aspect;
    _image.frame = CGRectMake((width - cardWidth) / 2, 0, cardWidth, height);
    _caption.frame = CGRectMake(0, imageHeight, width, 20);
}

- (NSString *)currentName {
    NSString *identifier = SGLockCardStyleID();
    NSDictionary *style = SGLockCardBuiltinStyles()[identifier];
    if (!style) {
        for (NSDictionary *entry in SGLockCardCatalogStyles())
            if ([entry[@"id"] isEqualToString:identifier]) { style = entry; break; }
    }
    if (!style) return identifier;
    return [style[@"author"] length]
        ? [NSString stringWithFormat:@"%@ · %@", style[@"name"], style[@"author"]]
        : [NSString stringWithFormat:@"%@", style[@"name"]];
}

- (void)reload {
    _caption.text = [self currentName];
    NSString *identifier = SGLockCardStyleID();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        SGLockCardRegisterFonts();
        NSString *error = nil;
        UIImage *image = SGLockCardRender(identifier, SGLockCardSampleData(), nil, 393, 852, 2, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            _image.image = image;
        });
    });
}
@end

// The page itself: the preview header, the rows, and a reload whenever the style or the
// catalog moves under it.
static NSArray<SGModSection *> *SGCardStyleSections(void);

@interface SGCardStylesController : SGModPage
@property (nonatomic, strong) SGCardPreview *preview;
@end

@implementation SGCardStylesController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.preview = [SGCardPreview new];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(styleChanged)
                                               name:SGLockCardStyleDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(styleChanged)
                                               name:SGCatalogDidChangeNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.preview reload];
}

- (void)styleChanged {
    [self refreshVisibility];
    [self.preview reload];
    [self.tableView reloadData];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    UITableView *table = self.tableView;
    CGFloat width = table.bounds.size.width;
    self.preview.layoutMargins = UIEdgeInsetsMake(0, table.layoutMargins.left, 0, table.layoutMargins.right);
    CGSize size = CGSizeMake(width, [self.preview heightForWidth:width]);
    if (CGSizeEqualToSize(self.preview.bounds.size, size)) return;
    self.preview.frame = (CGRect){CGPointZero, size};
    table.tableHeaderView = self.preview;
}
@end

// One row per style: the value carries the tick, a tap registers the fonts and stores the
// choice; the notification reloads the page. Catalog rows hide while their entry is absent.
static void SGCardAddStyle(NSDictionary *style, NSMutableArray<SGModRow *> *rows) {
    NSString *identifier = style[@"id"];
    BOOL builtin = [SGLockCardBuiltinStyles()[identifier] isKindOfClass:NSDictionary.class];
    NSString *subtitle = builtin ? @"built in" : ([style[@"author"] length] ? style[@"author"] : @"catalog");
    SGModRow *row = SGStatActionRow(style[@"name"], subtitle, ^NSString * {
        return [SGLockCardStyleID() isEqualToString:identifier] ? @"✓" : @"";
    }, ^{
        SGLockCardRegisterFonts();
        SGLockCardSetStyle(identifier);
    });
    row.visible = ^BOOL {
        if (builtin) return YES;
        for (NSDictionary *entry in SGLockCardCatalogStyles())
            if ([entry[@"id"] isEqualToString:identifier]) return YES;
        return NO;
    };
    [rows addObject:row];
}

static NSArray<SGModSection *> *SGCardStyleSections(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSString *identifier in @[@"builtin:classic", @"builtin:vinyl", @"builtin:messages"])
        SGCardAddStyle(SGLockCardBuiltinStyles()[identifier], rows);
    for (NSDictionary *style in SGLockCardCatalogStyles())
        SGCardAddStyle(style, rows);
    // placeholder rows keep the catalog's place: they show once their entries land
    NSUInteger known = SGLockCardCatalogStyles().count;
    SGModRow *refresh = SGActionRow(@"Refresh catalog",
        known ? @"Fetch the style catalog again" : @"Fetch the styles from the catalog server", ^{
        SGLockCardRefreshCatalog();
    });
    refresh.refreshOn = SGCatalogDidChangeNotification;
    [rows addObject:refresh];
    return @[SGNotedSection(nil, rows,
        @"A style's fonts come from the catalog's fonts the first time it is chosen.")];
}

UIViewController *SGLockCardStylesPage(void) {
    return [[SGCardStylesController alloc] initWithTitle:@"Lock screen card"
        intro:@"The lyric card the lock screen shows. Three looks ship with the mod; the styles catalog adds more, downloaded and kept."
        sections:SGCardStyleSections() footer:nil];
}
