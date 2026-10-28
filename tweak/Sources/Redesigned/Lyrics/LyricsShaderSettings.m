#import "LyricsShaderSettings.h"
#import "Redesigned/Player/LyricsShaders/LyricsShaders.h"
#import "Core/SGCore.h"
#import "Shared/Catalog/SGCatalog.h"

static NSArray<NSDictionary *> *allInfos(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *info in SGRLyricsShaderInfos()) {
        if ([info isKindOfClass:NSDictionary.class] && [info[@"identifier"] isKindOfClass:NSString.class]) [out addObject:info];
    }
    return out;
}

static NSDictionary *infoFor(NSString *identifier) {
    for (NSDictionary *info in allInfos()) if ([info[@"identifier"] isEqualToString:identifier]) return info;
    return nil;
}

static NSString *displayName(NSDictionary *info) {
    NSString *name = info[@"name"];
    NSString *author = info[@"author"];
    return author.length ? [NSString stringWithFormat:@"%@ · %@", name, author] : name ?: @"Shader";
}

static NSString *cacheState(NSString *identifier) {
    if (!SGRLyricsShaderIsCatalogIdentifier(identifier)) return @"Built in";
    return SGRLyricsShaderIsDownloaded(identifier) ? @"Downloaded" : @"Not downloaded";
}

@interface SGRLyricsShaderParamsPage : SGModPage
- (instancetype)initWithIdentifier:(NSString *)identifier;
@end

@implementation SGRLyricsShaderParamsPage {
    NSString *_identifier;
}

- (instancetype)initWithIdentifier:(NSString *)identifier {
    NSDictionary *info = infoFor(identifier);
    NSMutableArray *rows = [NSMutableArray array];
    NSDictionary *values = SGRLyricsShaderParamValues(identifier);
    for (NSDictionary *param in info[@"params"]) {
        NSString *paramID = param[@"id"];
        NSString *label = param[@"label"] ?: paramID;
        NSString *type = param[@"type"] ?: @"float";
        if (!paramID.length) continue;
        if ([type isEqualToString:@"toggle"]) {
            SGModRow *row = SGOptionRow(label, nil, nil);
            row.key = [NSString stringWithFormat:@"spotifyglass.redesign.lyricsShader.param.%@.%@", identifier, paramID];
            row.defaultOn = [values[paramID] boolValue];
            row.changed = ^(BOOL on) { SGRLyricsShaderSetParamValue(identifier, paramID, @(on)); };
            [rows addObject:row];
        } else if ([type isEqualToString:@"color"] || [type isEqualToString:@"colour"]) {
            SGModRow *row = SGStatActionRow(label, nil, ^NSString *{ return SGRLyricsShaderParamValues(identifier)[paramID]; }, ^{
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:label message:@"Enter a hex colour such as #ffffff." preferredStyle:UIAlertControllerStyleAlert];
                [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = SGRLyricsShaderParamValues(identifier)[paramID]; field.placeholder = @"#ffffff"; }];
                [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
                    NSString *value = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    if (value.length) SGRLyricsShaderSetParamValue(identifier, paramID, value);
                }]];
                [SGTopController() presentViewController:alert animated:YES completion:nil];
            });
            row.refreshOn = SGRLyricsShaderDidChangeNotification;
            [rows addObject:row];
        } else {
            double minimum = [param[@"min"] doubleValue];
            double maximum = [param[@"max"] doubleValue];
            double step = [param[@"step"] doubleValue];
            if (maximum <= minimum) maximum = 1;
            if (step <= 0) step = 0.01;
            [rows addObject:SGSliderRow(label, nil, minimum, maximum, step,
                ^double { return [SGRLyricsShaderParamValues(identifier)[paramID] doubleValue]; },
                ^(double value) { SGRLyricsShaderSetParamValue(identifier, paramID, @(value)); },
                ^NSString *(double value) { return [NSString stringWithFormat:@"%.2f", value]; })];
        }
    }
    if (!rows.count) [rows addObject:SGStatRow(@"Parameters", ^NSString *{ return @"No adjustable values"; })];
    self = [super initWithTitle:info[@"name"] ?: @"Lyrics shader settings" intro:nil sections:@[SGSection(nil, rows)] footer:nil];
    _identifier = [identifier copy];
    return self;
}
@end

@interface SGRLyricsShaderDetailPage : SGModPage
- (instancetype)initWithInfo:(NSDictionary *)info;
@end

@implementation SGRLyricsShaderDetailPage {
    NSDictionary *_info;
    SGModRow *_state;
}

- (instancetype)initWithInfo:(NSDictionary *)info {
    _info = info;
    NSString *identifier = info[@"identifier"];
    NSMutableArray *rows = [NSMutableArray array];
    SGModRow *use = SGActionRow(@"Use this look", cacheState(identifier), ^{
        if (SGRLyricsShaderIsCatalogIdentifier(identifier) && !SGRLyricsShaderIsDownloaded(identifier)) {
            SGRLyricsShaderDownload(identifier, ^(NSError *error) {
                if (!error) { SGRLyricsShaderSetStyle(identifier); [self.navigationController popViewControllerAnimated:YES]; }
            });
        } else { SGRLyricsShaderSetStyle(identifier); [self.navigationController popViewControllerAnimated:YES]; }
    });
    use.refreshOn = SGRLyricsShaderDidChangeNotification;
    [rows addObject:use];
    SGModRow *favourite = SGOptionRow(@"Favourite", @"Keep this shader in My shaders", nil);
    favourite.key = [NSString stringWithFormat:@"spotifyglass.redesign.lyricsShader.favourite.%@", identifier];
    favourite.defaultOn = SGRLyricsShaderIsFavourite(identifier);
    favourite.changed = ^(BOOL on) { SGRLyricsShaderSetFavourite(identifier, on); };
    [rows addObject:favourite];
    if (SGRLyricsShaderIsCatalogIdentifier(identifier)) {
        SGModRow *download = SGActionRow(@"Preview / download", @"Fetch the shader only after you ask for it", ^{
            SGRLyricsShaderDownload(identifier, ^(NSError *error) {
                if (error) SGLog(@"redesign lyrics shader download failed: %@", error.localizedDescription);
            });
        });
        download.refreshOn = SGRLyricsShaderDidChangeNotification;
        [rows addObject:download];
        SGModRow *remove = SGActionRow(@"Remove download", @"Keep the catalog entry and favourites, remove its cached shader", ^{
            SGRLyricsShaderRemove(identifier);
        });
        remove.visible = ^BOOL { return SGRLyricsShaderIsDownloaded(identifier); };
        remove.refreshOn = SGRLyricsShaderDidChangeNotification;
        [rows addObject:remove];
    }
    SGModRow *params = SGPageRow(@"Parameters", ^UIViewController *{ return [[SGLyricsShaderParamsPage alloc] initWithIdentifier:identifier]; });
    params.visible = ^BOOL { return [info[@"params"] isKindOfClass:NSArray.class] && [info[@"params"] count] > 0; };
    [rows addObject:params];
    NSString *detail = info[@"detail"] ?: @"";
    NSString *author = info[@"author"] ?: @"";
    NSString *intro = author.length ? [NSString stringWithFormat:@"%@\n\nBy %@", detail, author] : detail;
    return [super initWithTitle:info[@"name"] ?: @"Lyrics shader" intro:intro sections:@[SGSection(nil, rows)] footer:nil];
}
@end

@interface SGRLyricsShaderBrowserPage : SGPage <UISearchResultsUpdating>
- (instancetype)initWithTitle:(NSString *)title infos:(NSArray<NSDictionary *> *)infos myOnly:(BOOL)myOnly;
@end

@implementation SGRLyricsShaderBrowserPage {
    NSArray<NSDictionary *> *_infos;
    BOOL _myOnly;
    UISearchController *_search;
}

- (instancetype)initWithTitle:(NSString *)title infos:(NSArray<NSDictionary *> *)infos myOnly:(BOOL)myOnly {
    if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    self.title = title;
    _infos = infos;
    _myOnly = myOnly;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = _search;
    self.definesPresentationContext = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload) name:SGRLyricsShaderDidChangeNotification object:nil];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }
- (void)reload { dispatch_async(dispatch_get_main_queue(), ^{ [self.tableView reloadData]; }); }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController { [self.tableView reloadData]; }
- (NSArray *)shown {
    NSString *query = _search.searchBar.text.lowercaseString ?: @"";
    NSMutableArray *shown = [NSMutableArray array];
    for (NSDictionary *info in _infos) {
        NSString *identifier = info[@"identifier"];
        if (_myOnly && !(SGRLyricsShaderIsDownloaded(identifier) || SGRLyricsShaderIsFavourite(identifier))) continue;
        NSString *haystack = [[NSString stringWithFormat:@"%@ %@ %@", info[@"name"] ?: @"", info[@"author"] ?: @"", info[@"detail"] ?: @""] lowercaseString];
        if (!query.length || [haystack containsString:query]) [shown addObject:info];
    }
    return shown;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return [self shown].count; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"lyricsShader"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"lyricsShader"];
    NSDictionary *info = [self shown][(NSUInteger)indexPath.row];
    cell.textLabel.text = displayName(info);
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", info[@"detail"] ?: @"", cacheState(info[@"identifier"])];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *info = [self shown][(NSUInteger)indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self.navigationController pushViewController:[[SGLyricsShaderDetailPage alloc] initWithInfo:info] animated:YES];
}
@end

static NSArray<NSDictionary *> *catalogOnly(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *info in allInfos()) if (![info[@"builtin"] boolValue]) [out addObject:info];
    return out;
}

static UIViewController *pickerPage(NSString *title, BOOL catalog) {
    NSArray *infos = catalog ? catalogOnly() : allInfos();
    SGModPage *page = [[SGModPage alloc] initWithTitle:title intro:nil sections:@[
        SGSection(nil, @[SGPageRow(@"Browse and search", ^UIViewController *{ return [[SGLyricsShaderBrowserPage alloc] initWithTitle:title infos:infos myOnly:NO]; })])
    ] footer:nil];
    return page;
}

SGModRow *SGRLyricsShaderLookRow(void) {
    SGModRow *row = SGPageRow(@"Look", ^UIViewController *{ return pickerPage(@"Lyrics look", NO); });
    row.value = ^NSString *{ NSDictionary *info = infoFor(SGRLyricsShaderStyle()); return info[@"name"] ?: @"Poster"; };
    return row;
}

SGModRow *SGRLyricsShaderBrowseRow(void) {
    return SGPageRow(@"Browse shaders", ^UIViewController *{ return [[SGLyricsShaderBrowserPage alloc] initWithTitle:@"Browse shaders" infos:catalogOnly() myOnly:NO]; });
}

SGModRow *SGRLyricsShaderMyRow(void) {
    return SGPageRow(@"My shaders", ^UIViewController *{ return [[SGLyricsShaderBrowserPage alloc] initWithTitle:@"My shaders" infos:catalogOnly() myOnly:YES]; });
}
