//
//  TX500CallsignLookupService.m
//  Lab599 Utility
//
//  Callsign Intelligence & Station Photo Service
//

#import "TX500CallsignLookupService.h"

@implementation TX500LookupResult

- (instancetype)init {
    self = [super init];
    if (self) {
        _callsign = @"";
        _name = @"";
        _source = @"";
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    TX500LookupResult *c = [[[self class] allocWithZone:zone] init];
    c.callsign = [self.callsign copy];
    c.name = [self.name copy];
    c.firstName = [self.firstName copy];
    c.lastName = [self.lastName copy];
    c.qth = [self.qth copy];
    c.state = [self.state copy];
    c.county = [self.county copy];
    c.country = [self.country copy];
    c.grid = [self.grid copy];
    c.dxcc = [self.dxcc copy];
    c.cqZone = [self.cqZone copy];
    c.ituZone = [self.ituZone copy];
    c.imageURL = [self.imageURL copy];
    c.email = [self.email copy];
    c.isLoTW = self.isLoTW;
    c.isEQSL = self.isEQSL;
    c.source = [self.source copy];
    return c;
}

- (BOOL)hasData {
    return (self.name.length > 0 || self.qth.length > 0 || self.country.length > 0 || self.grid.length > 0);
}

- (NSString *)displayLocation {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.qth.length > 0) [parts addObject:self.qth];
    if (self.state.length > 0) [parts addObject:self.state];
    if (self.country.length > 0) [parts addObject:self.country];
    return [parts componentsJoinedByString:@", "];
}

@end

@interface TX500CallsignLookupService ()

@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *cache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *imageCache;
@property (nonatomic, copy) NSString *qrzSessionKey;
@property (nonatomic, copy) NSString *hamqthSessionKey;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_queue_t serviceQueue;

@end

@implementation TX500CallsignLookupService

+ (instancetype)sharedService {
    static TX500CallsignLookupService *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[TX500CallsignLookupService alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSMutableDictionary dictionary];
        _imageCache = [NSMutableDictionary dictionary];
        _serviceQueue = dispatch_queue_create("ir.factoreal.tx500.lookup", DISPATCH_QUEUE_SERIAL);
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 12.0;
        config.timeoutIntervalForResource = 15.0;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
}

#pragma mark - Cache

- (void)clearCache {
    dispatch_sync(self.serviceQueue, ^{
        [self.cache removeAllObjects];
        [self.imageCache removeAllObjects];
        self.qrzSessionKey = nil;
        self.hamqthSessionKey = nil;
    });
}

#pragma mark - Primary Lookup

- (void)lookupCallsign:(NSString *)rawCallsign
            completion:(void (^)(TX500LookupResult * _Nullable result, NSError * _Nullable error))completion {
    if (!rawCallsign || rawCallsign.length == 0) {
        if (completion) completion(nil, nil);
        return;
    }

    NSString *callsign = [[rawCallsign stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    
    // Check in-memory cache (24 hours)
    __block TX500LookupResult *cachedResult = nil;
    dispatch_sync(self.serviceQueue, ^{
        NSDictionary *entry = self.cache[callsign];
        if (entry) {
            NSDate *savedAt = entry[@"savedAt"];
            if (savedAt && [[NSDate date] timeIntervalSinceDate:savedAt] < 86400.0) {
                cachedResult = [entry[@"result"] copy];
            }
        }
    });

    if (cachedResult) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cachedResult, nil);
            });
        }
        return;
    }

    // Load credentials
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *qrzUser = [ud stringForKey:@"TX500_QRZ_Username"] ?: @"";
    NSString *qrzPass = [ud stringForKey:@"TX500_QRZ_Password"] ?: @"";
    NSString *hamUser = [ud stringForKey:@"TX500_HamQTH_Username"] ?: @"";
    NSString *hamPass = [ud stringForKey:@"TX500_HamQTH_Password"] ?: @"";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TX500LookupResult *result = nil;

        // Try QRZ first if configured
        if (qrzUser.length > 0 && qrzPass.length > 0) {
            result = [self performQRZLookupWithCallsign:callsign username:qrzUser password:qrzPass];
        }

        // Try HamQTH as fallback or primary
        if ((!result || !result.hasData) && hamUser.length > 0 && hamPass.length > 0) {
            TX500LookupResult *hamResult = [self performHamQTHLookupWithCallsign:callsign username:hamUser password:hamPass];
            if (hamResult && hamResult.hasData) {
                if (result) {
                    [self mergeResult:result fromResult:hamResult];
                } else {
                    result = hamResult;
                }
            }
        }

        if (result && result.hasData) {
            dispatch_sync(self.serviceQueue, ^{
                self.cache[callsign] = @{
                    @"savedAt": [NSDate date],
                    @"result": [result copy]
                };
            });
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(result, nil);
            }
        });
    });
}

- (void)mergeResult:(TX500LookupResult *)target fromResult:(TX500LookupResult *)source {
    if (target.name.length == 0 && source.name.length > 0) target.name = source.name;
    if (target.qth.length == 0 && source.qth.length > 0) target.qth = source.qth;
    if (target.state.length == 0 && source.state.length > 0) target.state = source.state;
    if (target.country.length == 0 && source.country.length > 0) target.country = source.country;
    if (target.grid.length == 0 && source.grid.length > 0) target.grid = source.grid;
    if (target.dxcc.length == 0 && source.dxcc.length > 0) target.dxcc = source.dxcc;
    if (target.imageURL.length == 0 && source.imageURL.length > 0) target.imageURL = source.imageURL;
    if (!target.isLoTW && source.isLoTW) target.isLoTW = YES;
    if (!target.isEQSL && source.isEQSL) target.isEQSL = YES;
}

#pragma mark - QRZ XML Lookup

- (nullable NSString *)obtainQRZSessionWithUsername:(NSString *)username password:(NSString *)password {
    __block NSString *existingKey = nil;
    dispatch_sync(self.serviceQueue, ^{
        existingKey = self.qrzSessionKey;
    });
    if (existingKey.length > 0) return existingKey;

    NSString *endpoint = @"https://xmldata.qrz.com/xml/current/";
    NSString *postStr = [NSString stringWithFormat:@"username=%@&password=%@&agent=%@",
                         [self urlEncode:username], [self urlEncode:password], [self urlEncode:@"TX500-macOS/1.0"]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *newKey = nil;

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        if (data) {
            NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!xml) xml = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
            if (xml) {
                newKey = [TX500CallsignLookupService extractXMLTag:@"Key" fromString:xml];
            }
        }
        dispatch_semaphore_signal(sema);
    }] resume];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));

    if (newKey.length > 0) {
        dispatch_sync(self.serviceQueue, ^{
            self.qrzSessionKey = newKey;
        });
    }
    return newKey;
}

- (nullable TX500LookupResult *)performQRZLookupWithCallsign:(NSString *)callsign
                                                   username:(NSString *)username
                                                   password:(NSString *)password {
    NSString *key = [self obtainQRZSessionWithUsername:username password:password];
    if (!key || key.length == 0) return nil;

    NSString *urlStr = [NSString stringWithFormat:@"https://xmldata.qrz.com/xml/current/?s=%@&callsign=%@",
                        [self urlEncode:key], [self urlEncode:callsign]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = @"GET";

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *respXML = nil;

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        if (data) {
            respXML = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!respXML) respXML = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        }
        dispatch_semaphore_signal(sema);
    }] resume];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

    if (!respXML) return nil;

    // If session expired or invalid, clear and retry once
    if ([respXML localizedCaseInsensitiveContainsString:@"Session Timeout"] ||
        [respXML localizedCaseInsensitiveContainsString:@"Invalid session key"]) {
        dispatch_sync(self.serviceQueue, ^{
            self.qrzSessionKey = nil;
        });
        key = [self obtainQRZSessionWithUsername:username password:password];
        if (!key) return nil;

        urlStr = [NSString stringWithFormat:@"https://xmldata.qrz.com/xml/current/?s=%@&callsign=%@",
                  [self urlEncode:key], [self urlEncode:callsign]];
        req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
        sema = dispatch_semaphore_create(0);
        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            (void)resp; (void)err;
            if (data) {
                respXML = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            }
            dispatch_semaphore_signal(sema);
        }] resume];
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));
    }

    return [TX500CallsignLookupService parseQRZXML:respXML callsign:callsign];
}

#pragma mark - HamQTH XML Lookup

- (nullable NSString *)obtainHamQTHSessionWithUsername:(NSString *)username password:(NSString *)password {
    __block NSString *existingKey = nil;
    dispatch_sync(self.serviceQueue, ^{
        existingKey = self.hamqthSessionKey;
    });
    if (existingKey.length > 0) return existingKey;

    NSString *urlStr = [NSString stringWithFormat:@"https://www.hamqth.com/xml.php?u=%@&p=%@",
                        [self urlEncode:username], [self urlEncode:password]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *newKey = nil;

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        if (data) {
            NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (xml) {
                newKey = [TX500CallsignLookupService extractXMLTag:@"session_id" fromString:xml];
                if (!newKey) newKey = [TX500CallsignLookupService extractXMLTag:@"id" fromString:xml];
            }
        }
        dispatch_semaphore_signal(sema);
    }] resume];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));

    if (newKey.length > 0) {
        dispatch_sync(self.serviceQueue, ^{
            self.hamqthSessionKey = newKey;
        });
    }
    return newKey;
}

- (nullable TX500LookupResult *)performHamQTHLookupWithCallsign:(NSString *)callsign
                                                       username:(NSString *)username
                                                       password:(NSString *)password {
    NSString *key = [self obtainHamQTHSessionWithUsername:username password:password];
    if (!key || key.length == 0) return nil;

    NSString *urlStr = [NSString stringWithFormat:@"https://www.hamqth.com/xml.php?id=%@&callsign=%@&prg=TX500-macOS",
                        [self urlEncode:key], [self urlEncode:callsign]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSString *respXML = nil;

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        if (data) {
            respXML = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        dispatch_semaphore_signal(sema);
    }] resume];

    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

    if (!respXML) return nil;
    return [TX500CallsignLookupService parseHamQTHXML:respXML callsign:callsign];
}

#pragma mark - Station Photo Fetching

- (void)fetchImageForURLString:(NSString *)urlString
                    completion:(void (^)(NSImage * _Nullable image))completion {
    if (!urlString || urlString.length == 0) {
        if (completion) completion(nil);
        return;
    }

    __block NSImage *cached = nil;
    dispatch_sync(self.serviceQueue, ^{
        cached = self.imageCache[urlString];
    });
    if (cached) {
        if (completion) completion(cached);
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil);
        return;
    }

    [[self.urlSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp; (void)err;
        NSImage *img = nil;
        if (data && data.length > 0) {
            img = [[NSImage alloc] initWithData:data];
        }
        if (img) {
            dispatch_sync(self.serviceQueue, ^{
                self.imageCache[urlString] = img;
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(img);
        });
    }] resume];
}

#pragma mark - Connection Tests

- (void)testQRZCredentialsWithUsername:(NSString *)username
                              password:(NSString *)password
                            completion:(void (^)(BOOL success, NSString *message))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *endpoint = @"https://xmldata.qrz.com/xml/current/";
        NSString *postStr = [NSString stringWithFormat:@"username=%@&password=%@&agent=%@",
                             [self urlEncode:username], [self urlEncode:password], [self urlEncode:@"TX500-macOS/1.0"]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            (void)resp;
            BOOL ok = NO;
            NSString *msg = err ? [err localizedDescription] : @"No response from QRZ.com";
            if (data) {
                NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSString *key = [TX500CallsignLookupService extractXMLTag:@"Key" fromString:xml];
                if (key.length > 0) {
                    ok = YES;
                    msg = [NSString stringWithFormat:@"QRZ XML Login Successful! Session Key: %@", [key substringToIndex:MIN(8, key.length)]];
                } else {
                    NSString *errorMsg = [TX500CallsignLookupService extractXMLTag:@"Error" fromString:xml];
                    msg = errorMsg.length > 0 ? errorMsg : @"Invalid username or password.";
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, msg);
            });
        }] resume];
    });
}

- (void)testHamQTHCredentialsWithUsername:(NSString *)username
                                 password:(NSString *)password
                               completion:(void (^)(BOOL success, NSString *message))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *urlStr = [NSString stringWithFormat:@"https://www.hamqth.com/xml.php?u=%@&p=%@",
                            [self urlEncode:username], [self urlEncode:password]];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];

        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            (void)resp;
            BOOL ok = NO;
            NSString *msg = err ? [err localizedDescription] : @"No response from HamQTH.com";
            if (data) {
                NSString *xml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                NSString *key = [TX500CallsignLookupService extractXMLTag:@"session_id" fromString:xml];
                if (!key) key = [TX500CallsignLookupService extractXMLTag:@"id" fromString:xml];
                if (key.length > 0) {
                    ok = YES;
                    msg = [NSString stringWithFormat:@"HamQTH Login Successful! Session ID: %@", [key substringToIndex:MIN(8, key.length)]];
                } else {
                    NSString *errorMsg = [TX500CallsignLookupService extractXMLTag:@"error" fromString:xml];
                    msg = errorMsg.length > 0 ? errorMsg : @"Invalid username or password.";
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, msg);
            });
        }] resume];
    });
}

#pragma mark - XML Parsing Helpers

+ (nullable NSString *)extractXMLTag:(NSString *)tag fromString:(NSString *)xml {
    if (!xml || xml.length == 0 || !tag || tag.length == 0) return nil;
    NSString *pattern = [NSString stringWithFormat:@"<(?i:%@)(?:\\s[^>]*)?>([\\s\\S]*?)</(?i:%@)>", tag, tag];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [regex firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    if (m && m.numberOfRanges >= 2) {
        NSString *val = [xml substringWithRange:[m rangeAtIndex:1]];
        return [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return nil;
}

+ (TX500LookupResult *)parseQRZXML:(NSString *)xml callsign:(NSString *)callsign {
    TX500LookupResult *res = [[TX500LookupResult alloc] init];
    res.callsign = [callsign uppercaseString];
    res.source = @"QRZ XML";

    if (!xml || xml.length == 0) return res;

    NSString *fname = [self extractXMLTag:@"fname" fromString:xml];
    NSString *name = [self extractXMLTag:@"name" fromString:xml];
    NSString *nameFmt = [self extractXMLTag:@"name_fmt" fromString:xml];

    res.firstName = fname;
    res.lastName = name;
    if (nameFmt.length > 0) {
        res.name = nameFmt;
    } else {
        NSMutableArray *p = [NSMutableArray array];
        if (fname.length > 0) [p addObject:fname];
        if (name.length > 0) [p addObject:name];
        res.name = [p componentsJoinedByString:@" "];
    }

    res.qth = [self extractXMLTag:@"addr2" fromString:xml];
    res.state = [self extractXMLTag:@"state" fromString:xml];
    res.county = [self extractXMLTag:@"county" fromString:xml];
    res.country = [self extractXMLTag:@"land" fromString:xml];
    if (res.country.length == 0) res.country = [self extractXMLTag:@"country" fromString:xml];
    res.grid = [self extractXMLTag:@"grid" fromString:xml];
    res.dxcc = [self extractXMLTag:@"dxcc" fromString:xml];
    res.cqZone = [self extractXMLTag:@"cqzone" fromString:xml];
    res.ituZone = [self extractXMLTag:@"ituzone" fromString:xml];
    res.imageURL = [self extractXMLTag:@"image" fromString:xml];
    res.email = [self extractXMLTag:@"email" fromString:xml];
    res.isLoTW = [[self extractXMLTag:@"lotw" fromString:xml] isEqualToString:@"1"];
    res.isEQSL = [[self extractXMLTag:@"eqsl" fromString:xml] isEqualToString:@"1"];

    return res;
}

+ (TX500LookupResult *)parseHamQTHXML:(NSString *)xml callsign:(NSString *)callsign {
    TX500LookupResult *res = [[TX500LookupResult alloc] init];
    res.callsign = [callsign uppercaseString];
    res.source = @"HamQTH";

    if (!xml || xml.length == 0) return res;

    NSString *nick = [self extractXMLTag:@"nick" fromString:xml];
    NSString *adrName = [self extractXMLTag:@"adr_name" fromString:xml];
    NSString *name = [self extractXMLTag:@"name" fromString:xml];

    if (nick.length > 0) res.name = nick;
    else if (adrName.length > 0) res.name = adrName;
    else if (name.length > 0) res.name = name;

    res.qth = [self extractXMLTag:@"adr_city" fromString:xml];
    if (res.qth.length == 0) res.qth = [self extractXMLTag:@"qth" fromString:xml];
    res.state = [self extractXMLTag:@"us_state" fromString:xml];
    res.country = [self extractXMLTag:@"country" fromString:xml];
    res.grid = [self extractXMLTag:@"grid" fromString:xml];
    res.dxcc = [self extractXMLTag:@"adif" fromString:xml];
    if (res.dxcc.length == 0) res.dxcc = [self extractXMLTag:@"dxcc" fromString:xml];
    res.cqZone = [self extractXMLTag:@"cq" fromString:xml];
    res.ituZone = [self extractXMLTag:@"itu" fromString:xml];
    res.imageURL = [self extractXMLTag:@"picture" fromString:xml];
    res.email = [self extractXMLTag:@"email" fromString:xml];
    res.isLoTW = [[[self extractXMLTag:@"lotw" fromString:xml] uppercaseString] isEqualToString:@"Y"];
    res.isEQSL = [[[self extractXMLTag:@"eqsl" fromString:xml] uppercaseString] isEqualToString:@"Y"];

    return res;
}

- (NSString *)urlEncode:(NSString *)str {
    NSMutableCharacterSet *set = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [set addCharactersInString:@"-._~"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:set] ?: str;
}

@end
