#import "Lab599FirmwareCatalog.h"
#import "TX500Transfer.h"
#import <CommonCrypto/CommonDigest.h>
#import <string.h>

@implementation Lab599FirmwareItem

- (NSString *)displayTitle {
    if (self.isLatest) {
        return [NSString stringWithFormat:@"%@  [Latest - %@]", self.title, self.fileSizeString ?: @""];
    }
    return [NSString stringWithFormat:@"%@  [%@]", self.title, self.fileSizeString ?: @""];
}

@end

@interface Lab599FirmwareCatalog () <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSURLSession *catalogSession;
@property(nonatomic, strong) NSURLSessionDownloadTask *currentDownloadTask;
@property(nonatomic, copy) void (^currentProgressHandler)(double, int64_t, int64_t);
@property(nonatomic, copy) void (^currentCompletionHandler)(NSURL * _Nullable, NSString * _Nullable, NSError * _Nullable);
@property(nonatomic, strong) NSURL *currentDestinationURL;
@end

// These values were calculated from the files linked by lab599.com/downloads
// and lab599.ru/downloads on 2026-09-29. A newly published file must be
// reviewed and added here before the in-app downloader can use it.
static NSDictionary<NSString *, NSString *> *KnownFirmwareHashes(void) {
    static NSDictionary<NSString *, NSString *> *hashes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hashes = @{
            @"/TX500/mtrx1.30.00.fw": @"2162fed7d27987507c8b412f3d38478c0a670a906a0c747578d7c975ad5a04ea",
            @"/TX500/mtrx1.29.06.fw": @"190a3f29f05bc4aa3de993faa35b158c449645475b09ad6d69a1ef3ab5169425",
            @"/TX500/mtrx1.29.01.fw": @"89324013f81ea4cca24de97026d8765b267bdd0e380839ae1893847d20e5f64f",
            @"/TX500/mtrx1.26.06.fw": @"0f1ee814b6ee02356785359a2cd40e2c842e2da4b2da5210c6a0c7f5702e3635",
            @"/TX500/mtrx1.25.06.fw": @"60fbee18d068752959613f07d782e74f450d9555f8f340e18026a083868062c6",
            @"/TX500/mtrx1.23.09.fw": @"5323df8cb57e5e759222404110e7a9d9af2d13bbcfd8093676599f72a777f8ff",
            @"/TX500/mtrx1.16.06.fw": @"56eac683c3ffb56ecb4776e6d1c95ee12b82de1f022c2945c30b2e8a674d9bc1",
            @"/TX500/mtrx1.13.08.fw": @"b4f07877b6870b186c8cc03405fc8f2a464b9c1e311e7d7e570f319e78f59999",
            @"/TX500MP/mtrxMP1.30.00.fw": @"a9c616bf783c4e38f0707803088c28362c72e5ba09ca40dfa44f3b97b801bf19",
            @"/TX500MP/mtrxMP1.30.00b27.fw": @"38e9b5dedc5a301b15cb2b53ba4771d038690fb909f02dfbe1d023059fd3e49d",
            @"/TX500MP/mtrxMP1.29.01.fw": @"05ee1ea8030149a35a03a83bee57b9ad703d51a6f77622bfda2abeaa70c1ed72",
            @"/TX500MP/mtrxMP1.26.06.fw": @"ec85dbfa1385f6e961faa7e9c6ff647f11360cba18670b40eeeb6f722ae0c72a",
            @"/TX500MP/mtrxMP1.25.06.fw": @"bdc2554739e5b36363e024d148136b62b01384bb7ad1e4d753ee6d083f16f1fd",
            @"/TX500MP/mtrxMP1.24.23.fw": @"23b21fa6209ec6461b0bd917a03aeb7a493b0db9c16fefc58813221034251823",
            @"/TX500PRO/mtrx_pro1.29.05.fw": @"ec7aaaf402ed242cc65c2200b74d8a180bf9fdc7f4df36c6f800f75bd341a6ae",
            @"/TX500PRO/mtrx_alt1.29.05.fw": @"af65e2338671f6e10a93b7ab241d835d25e65f29d74509825949aa159a30f80f",
            @"/TX500PRO/mtrx_pro1.23.09.fw": @"50515d9e22456bdf792097ffa1f5b14f12aeb82efe7a191466f88b47498b901a",
            @"/TX500PRO/mtrx_pro1.17.13.fw": @"e26c60720b4171cf0c18b10c0893ea30b3602318cb3498a8d1cd01c4aadd84fe",
            @"/TX500PRO/mtrx_pro1.21.01.fw": @"66fb5c02fc862c0bbedbc215483146271b848a58d6ab85650ee00bf5ea59a8b1"
        };
    });
    return hashes;
}

static NSString *ReviewedModelForPath(NSString *path) {
    if ([path hasPrefix:@"/TX500/mtrx"]) return @"TX-500 Discovery";
    if ([path hasPrefix:@"/TX500MP/mtrxMP"]) return @"TX-500MP";
    if ([path hasPrefix:@"/TX500PRO/mtrx_alt"]) return @"TX-500PRO ALTAI";
    if ([path hasPrefix:@"/TX500PRO/mtrx_pro"]) return @"TX-500PRO";
    return nil;
}

static BOOL OfficialFirmwareURL(NSURL *url) {
    return [url.scheme.lowercaseString isEqualToString:@"https"] &&
        [url.host.lowercaseString isEqualToString:@"downloads.lab599.com"] &&
        url.port == nil && url.user == nil && url.password == nil &&
        url.query == nil && url.fragment == nil &&
        KnownFirmwareHashes()[url.path] != nil;
}

@implementation Lab599FirmwareCatalog

+ (NSString *)reviewedModelForFirmwareData:(NSData *)data {
    if (!data || data.length > 1024 * 1024 || TXFirmwareValidationError(data)) return nil;
    NSString *digest = TXFirmwareSHA256(data);
    const uint8_t *bytes = data.bytes;
    NSString *matchedModel = nil;
    for (NSString *path in KnownFirmwareHashes()) {
        if (![digest isEqualToString:KnownFirmwareHashes()[path]]) continue;
        NSString *model = ReviewedModelForPath(path);
        if (!model || (matchedModel && ![matchedModel isEqualToString:model])) return nil;
        // PRO and ALTAI releases use the same BL20 ID as Discovery, so their
        // target must come from the reviewed complete-file digest instead.
        if ([model isEqualToString:@"TX-500 Discovery"] &&
            memcmp(bytes + 12, "\xaa\xb4\x1a\xc6", 4) != 0) return nil;
        if ([model isEqualToString:@"TX-500MP"] &&
            memcmp(bytes + 12, "\x96\x3b\xcd\xf4", 4) != 0) return nil;
        matchedModel = model;
    }
    return matchedModel;
}

+ (NSString *)preflightErrorForFirmwareData:(NSData *)data
                          declaredRadioModel:(NSString *)declaredRadioModel {
    NSString *model = [self reviewedModelForFirmwareData:data];
    if (!model) return @"Firmware is not a reviewed official release or its BL20 model ID is inconsistent. No data was sent to the radio.";
    if (![model isEqualToString:declaredRadioModel])
        return [NSString stringWithFormat:@"Model mismatch: this firmware targets %@, but the radio model was declared as %@. No data was sent to the radio.",
                model, declaredRadioModel.length ? declaredRadioModel : @"not selected"];
    return nil;
}

+ (NSString *)CATIdentityErrorForFirmwareModel:(NSString *)firmwareModel
                                           reply:(NSString *)reply {
    NSString *expected = [firmwareModel isEqualToString:@"TX-500MP"] ? @"ID505;" :
        ([@[@"TX-500 Discovery", @"TX-500PRO", @"TX-500PRO ALTAI"] containsObject:firmwareModel] ? @"ID500;" : nil);
    if (!expected) return @"The firmware target is not a supported radio model.";
    if (![reply isEqualToString:expected])
        return [NSString stringWithFormat:@"CAT identity check failed. %@ requires %@ in LAB599 CAT mode; the radio replied %@. No firmware was sent.",
                firmwareModel, expected, reply.length ? reply : @"nothing"];
    return nil;
}

+ (instancetype)sharedCatalog {
    static Lab599FirmwareCatalog *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[Lab599FirmwareCatalog alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest = 20.0;
        config.timeoutIntervalForResource = 60.0;
        self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        self.catalogSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

+ (NSArray<Lab599FirmwareItem *> *)fallbackFirmwareCatalog {
    NSMutableArray<Lab599FirmwareItem *> *items = [NSMutableArray array];

    Lab599FirmwareItem *tx500Latest = [Lab599FirmwareItem new];
    tx500Latest.title = @"TX-500 Firmware v1.30.00";
    tx500Latest.model = @"TX-500 Discovery";
    tx500Latest.version = @"1.30.00";
    tx500Latest.fileSizeString = @"240 KB";
    tx500Latest.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500/mtrx1.30.00.fw"];
    tx500Latest.changelog = @"Official TX-500 Discovery release.\n- Improved battery indicator\n- Audio engine and CAT improvements";
    tx500Latest.isLatest = YES;
    [items addObject:tx500Latest];

    Lab599FirmwareItem *tx500Prev = [Lab599FirmwareItem new];
    tx500Prev.title = @"TX-500 Firmware v1.29.06";
    tx500Prev.model = @"TX-500 Discovery";
    tx500Prev.version = @"1.29.06";
    tx500Prev.fileSizeString = @"240 KB";
    tx500Prev.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500/mtrx1.29.06.fw"];
    tx500Prev.changelog = @"Stable release for TX-500 Discovery.";
    tx500Prev.isLatest = NO;
    [items addObject:tx500Prev];

    Lab599FirmwareItem *mpLatest = [Lab599FirmwareItem new];
    mpLatest.title = @"TX-500MP Firmware v1.30.00";
    mpLatest.model = @"TX-500MP";
    mpLatest.version = @"1.30.00";
    mpLatest.fileSizeString = @"224 KB";
    mpLatest.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500MP/mtrxMP1.30.00.fw"];
    mpLatest.changelog = @"Official TX-500MP release.\n- Optimized for TX-500MP transceiver hardware.";
    mpLatest.isLatest = YES;
    [items addObject:mpLatest];

    Lab599FirmwareItem *mpPatch = [Lab599FirmwareItem new];
    mpPatch.title = @"TX-500MP HAM-Bands Patch v1.30.00B27";
    mpPatch.model = @"TX-500MP";
    mpPatch.version = @"1.30.00B27";
    mpPatch.fileSizeString = @"224 KB";
    mpPatch.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500MP/mtrxMP1.30.00b27.fw"];
    mpPatch.changelog = @"HAM-Bands Patch for TX-500MP.";
    mpPatch.isLatest = NO;
    [items addObject:mpPatch];

    Lab599FirmwareItem *proLatest = [Lab599FirmwareItem new];
    proLatest.title = @"TX-500PRO Firmware v1.29.05";
    proLatest.model = @"TX-500PRO";
    proLatest.version = @"1.29.05";
    proLatest.fileSizeString = @"225 KB";
    proLatest.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500PRO/mtrx_pro1.29.05.fw"];
    proLatest.changelog = @"Official TX-500PRO release, listed on lab599.ru/downloads.";
    proLatest.isLatest = YES;
    [items addObject:proLatest];

    Lab599FirmwareItem *altaiLatest = [Lab599FirmwareItem new];
    altaiLatest.title = @"TX-500PRO ALTAI Firmware v1.29.05";
    altaiLatest.model = @"TX-500PRO ALTAI";
    altaiLatest.version = @"1.29.05";
    altaiLatest.fileSizeString = @"223 KB";
    altaiLatest.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500PRO/mtrx_alt1.29.05.fw"];
    altaiLatest.changelog = @"Official TX-500PRO ALTAI release, listed on lab599.ru/downloads.";
    altaiLatest.isLatest = YES;
    [items addObject:altaiLatest];

    for (Lab599FirmwareItem *item in items) item.expectedSHA256 = KnownFirmwareHashes()[item.downloadURL.path];
    return items;
}

- (void)fetchAvailableFirmwaresWithCompletion:(void (^)(NSArray<Lab599FirmwareItem *> *items, NSError * _Nullable error))completion {
    // Both official pages are read; latest versions are compared after parsing.
    NSArray<NSString *> *pages = @[@"https://lab599.com/downloads", @"https://lab599.ru/downloads"];
    NSMutableArray *htmlPages = [NSMutableArray array];
    for (NSUInteger i = 0; i < pages.count; i++) [htmlPages addObject:[NSNull null]];
    __block NSError *lastError = nil;
    dispatch_group_t group = dispatch_group_create();

    for (NSUInteger i = 0; i < pages.count; i++) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:pages[i]]];
        [request setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)" forHTTPHeaderField:@"User-Agent"];
        dispatch_group_enter(group);
        NSURLSessionDataTask *task = [self.catalogSession dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            NSString *html = nil;
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            BOOL sameHost = [response.URL.scheme.lowercaseString isEqualToString:@"https"] &&
                [response.URL.host.lowercaseString isEqualToString:[NSURL URLWithString:pages[i]].host.lowercaseString];
            if (data && !error && http.statusCode == 200 && sameHost && data.length <= 2 * 1024 * 1024) {
                html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!html) html = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            }
            @synchronized (htmlPages) {
                if (html) {
                    htmlPages[i] = html;
                } else {
                    lastError = error ?: [NSError errorWithDomain:@"Lab599" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid firmware catalog response"}];
                }
            }
            dispatch_group_leave(group);
        }];
        [task resume];
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        NSMutableArray<NSString *> *loaded = [NSMutableArray array];
        for (id page in htmlPages) if ([page isKindOfClass:NSString.class]) [loaded addObject:page];
        NSArray<Lab599FirmwareItem *> *parsed = loaded.count ? [self parseFirmwareItemsFromHTML:[loaded componentsJoinedByString:@"\n"]] : @[];
        if (parsed.count == 0) {
            completion([Lab599FirmwareCatalog fallbackFirmwareCatalog], lastError);
            return;
        }
        completion(parsed, nil);
    });
}

- (NSArray<Lab599FirmwareItem *> *)parseFirmwareItemsFromHTML:(NSString *)html {
    NSMutableArray<Lab599FirmwareItem *> *results = [NSMutableArray array];
    NSMutableDictionary<NSString *, Lab599FirmwareItem *> *itemByUrl = [NSMutableDictionary dictionary];

    // Accept only HTTPS links on the exact official download host.
    NSRegularExpression *linkRegex = [NSRegularExpression regularExpressionWithPattern:@"<a\\s+[^>]*href=[\"'](https://downloads\\.lab599\\.com/[^\"'\\s]+\\.fw)[\"'][^>]*>(.*?)</a>"
                                                                               options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                                                                                 error:nil];
    NSArray<NSTextCheckingResult *> *matches = [linkRegex matchesInString:html options:0 range:NSMakeRange(0, html.length)];

    for (NSTextCheckingResult *match in matches) {
        NSString *urlString = [html substringWithRange:[match rangeAtIndex:1]];
        NSString *rawText = [html substringWithRange:[match rangeAtIndex:2]];
        NSURL *firmwareURL = [NSURL URLWithString:urlString];
        if (!OfficialFirmwareURL(firmwareURL)) continue;

        NSString *cleanText = [rawText stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, rawText.length)];
        cleanText = [cleanText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

        Lab599FirmwareItem *existing = itemByUrl[urlString];
        if (!existing) {
            existing = [Lab599FirmwareItem new];
            existing.downloadURL = firmwareURL;
            existing.expectedSHA256 = KnownFirmwareHashes()[firmwareURL.path];
            itemByUrl[urlString] = existing;
            [results addObject:existing];
        }

        if (cleanText.length > 0) {
            if ([cleanText rangeOfString:@"Kb" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [cleanText rangeOfString:@"MB" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                existing.fileSizeString = cleanText;
            } else if ([cleanText rangeOfString:@"Firmware" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [cleanText rangeOfString:@"Patch" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                existing.title = cleanText;
            }
        }
    }

    // Determine model and fallback titles for each item
    for (Lab599FirmwareItem *item in results) {
        NSString *path = item.downloadURL.path;
        if ([path hasPrefix:@"/TX500PRO/mtrx_alt"]) {
            item.model = @"TX-500PRO ALTAI";
        } else if ([path hasPrefix:@"/TX500PRO/mtrx_pro"]) {
            item.model = @"TX-500PRO";
        } else if ([path hasPrefix:@"/TX500MP/mtrxMP"]) {
            item.model = @"TX-500MP";
        } else if ([path hasPrefix:@"/TX500/mtrx"]) {
            item.model = @"TX-500 Discovery";
        } else {
            item.model = @"Lab599 Transceiver";
        }

        // Derive the displayed target and version from the reviewed URL path,
        // never from catalog HTML text that could mislabel another model.
        NSRegularExpression *verRegex = [NSRegularExpression regularExpressionWithPattern:@"v?(\\d+\\.\\d+\\.\\d+([A-Za-z0-9]+)?)"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
        NSString *filename = item.downloadURL.lastPathComponent;
        NSTextCheckingResult *verMatch = [verRegex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
        if (verMatch) {
            item.version = [filename substringWithRange:[verMatch rangeAtIndex:1]];
        } else {
            item.version = filename.stringByDeletingPathExtension;
        }
        BOOL patchRelease = [filename.lowercaseString containsString:@"b27"];
        item.title = [NSString stringWithFormat:@"%@ %@ v%@", item.model,
            patchRelease ? @"HAM-Bands Patch" : @"Firmware", item.version];

        // Search for nearby changelog in HTML
        NSRange urlRange = [html rangeOfString:item.downloadURL.absoluteString];
        if (urlRange.location != NSNotFound) {
            NSUInteger searchStart = urlRange.location;
            NSUInteger searchLen = MIN((NSUInteger)2500, html.length - searchStart);
            NSString *window = [html substringWithRange:NSMakeRange(searchStart, searchLen)];
            NSRange changelogRange = [window rangeOfString:@"Changelog:"];
            if (changelogRange.location != NSNotFound) {
                NSUInteger clStart = changelogRange.location;
                NSUInteger clLen = MIN((NSUInteger)800, window.length - clStart);
                NSString *clChunk = [window substringWithRange:NSMakeRange(clStart, clLen)];
                NSRange endDiv = [clChunk rangeOfString:@"</div>"];
                if (endDiv.location != NSNotFound) {
                    clChunk = [clChunk substringToIndex:endDiv.location];
                }
                NSString *cleanCL = [clChunk stringByReplacingOccurrencesOfString:@"<br\\s*/?>|</li>" withString:@"\n" options:NSRegularExpressionSearch range:NSMakeRange(0, clChunk.length)];
                cleanCL = [cleanCL stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, cleanCL.length)];
                cleanCL = [cleanCL stringByReplacingOccurrencesOfString:@"&nbsp;" withString:@" "];
                cleanCL = [cleanCL stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (cleanCL.length > 0) {
                    item.changelog = cleanCL;
                }
            }
        }
    }

    // A duplicate or stale page must not make an older release look newest.
    NSMutableDictionary<NSString *, Lab599FirmwareItem *> *latest = [NSMutableDictionary dictionary];
    for (Lab599FirmwareItem *item in results) {
        BOOL patchRelease = [item.title localizedCaseInsensitiveContainsString:@"Patch"] ||
            [item.downloadURL.lastPathComponent.lowercaseString containsString:@"b27"];
        if (patchRelease) continue;
        Lab599FirmwareItem *previous = latest[item.model];
        if (!previous || [item.version compare:previous.version options:NSNumericSearch] == NSOrderedDescending)
            latest[item.model] = item;
    }
    for (Lab599FirmwareItem *item in latest.allValues) item.isLatest = YES;

    return results;
}

- (NSURLSessionDownloadTask *)downloadFirmware:(Lab599FirmwareItem *)item
                                     progress:(void (^)(double progress, int64_t bytesWritten, int64_t totalExpected))progressHandler
                                   completion:(void (^)(NSURL * _Nullable localFileURL, NSString * _Nullable sha256, NSError * _Nullable error))completionHandler {
    NSString *expected = KnownFirmwareHashes()[item.downloadURL.path];
    if (!OfficialFirmwareURL(item.downloadURL) || ![item.expectedSHA256 isEqualToString:expected] || self.currentDownloadTask) {
        NSError *error = [NSError errorWithDomain:@"Lab599" code:-3 userInfo:@{NSLocalizedDescriptionKey:
            @"This firmware release is not in the reviewed SHA-256 list, or another download is active."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completionHandler(nil, nil, error); });
        return nil;
    }
    self.currentProgressHandler = progressHandler;
    self.currentCompletionHandler = completionHandler;

    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                          stringByAppendingPathComponent:@"Lab599FirmwareUpdater"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
    self.currentDestinationURL = [NSURL fileURLWithPath:[cacheDir stringByAppendingPathComponent:item.downloadURL.lastPathComponent]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:item.downloadURL];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [self.session downloadTaskWithRequest:request];
    self.currentDownloadTask = task;
    [task resume];
    return task;
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session; (void)response;
    // A redirect may not turn an approved download into another origin or file.
    completionHandler(OfficialFirmwareURL(request.URL) &&
                      [request.URL.absoluteString isEqualToString:task.originalRequest.URL.absoluteString] ? request : nil);
}

- (void)finishDownloadWithURL:(NSURL *)url hash:(NSString *)hash error:(NSError *)error {
    void (^completion)(NSURL *, NSString *, NSError *) = self.currentCompletionHandler;
    self.currentCompletionHandler = nil;
    self.currentProgressHandler = nil;
    self.currentDownloadTask = nil;
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(url, hash, error); });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)totalBytesWritten totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)bytesWritten;
    if (downloadTask != self.currentDownloadTask) return;
    if (totalBytesWritten > 1024 * 1024 || totalBytesExpectedToWrite > 1024 * 1024) {
        [downloadTask cancel];
        return;
    }
    if (self.currentProgressHandler) {
        void (^progress)(double, int64_t, int64_t) = self.currentProgressHandler;
        double p = totalBytesExpectedToWrite > 0 ? (double)totalBytesWritten / (double)totalBytesExpectedToWrite : 0.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            progress(p, totalBytesWritten, totalBytesExpectedToWrite);
        });
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    if (downloadTask != self.currentDownloadTask) return;
    NSHTTPURLResponse *http = [downloadTask.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)downloadTask.response : nil;
    if (http.statusCode != 200 || !OfficialFirmwareURL(downloadTask.response.URL) ||
        ![downloadTask.response.URL.absoluteString isEqualToString:downloadTask.originalRequest.URL.absoluteString]) {
        NSError *invalid = [NSError errorWithDomain:@"Lab599" code:-4 userInfo:@{NSLocalizedDescriptionKey: @"Firmware download came from an unexpected response or URL."}];
        [self finishDownloadWithURL:nil hash:nil error:invalid];
        return;
    }
    NSError *error = nil;
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:&error];
    if (!attributes || [attributes fileSize] > 1024 * 1024) {
        NSError *large = error ?: [NSError errorWithDomain:@"Lab599" code:-5 userInfo:@{NSLocalizedDescriptionKey: @"Firmware exceeds the 1 MB safety limit."}];
        [self finishDownloadWithURL:nil hash:nil error:large];
        return;
    }

    NSData *data = [NSData dataWithContentsOfURL:location options:0 error:&error];
    if (!data) {
        [self finishDownloadWithURL:nil hash:nil error:error];
        return;
    }

    NSString *validation = TXFirmwareValidationError(data);
    if (validation) {
        NSError *vError = [NSError errorWithDomain:@"Lab599" code:-2 userInfo:@{NSLocalizedDescriptionKey: validation}];
        [self finishDownloadWithURL:nil hash:nil error:vError];
        return;
    }

    NSString *hash = TXFirmwareSHA256(data);
    NSString *expected = KnownFirmwareHashes()[downloadTask.originalRequest.URL.path];
    if (![hash isEqualToString:expected]) {
        NSError *mismatch = [NSError errorWithDomain:@"Lab599" code:-6 userInfo:@{NSLocalizedDescriptionKey: @"Firmware SHA-256 does not match the reviewed release."}];
        [self finishDownloadWithURL:nil hash:nil error:mismatch];
        return;
    }
    if (![data writeToURL:self.currentDestinationURL options:NSDataWritingAtomic error:&error]) {
        [self finishDownloadWithURL:nil hash:nil error:error];
        return;
    }
    [self finishDownloadWithURL:self.currentDestinationURL hash:hash error:nil];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session;
    if (task == self.currentDownloadTask && error) [self finishDownloadWithURL:nil hash:nil error:error];
}

@end
