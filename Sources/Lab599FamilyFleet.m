#import "Lab599FamilyFleet.h"
#import <Cocoa/Cocoa.h>
#import <float.h>

static NSString * const Lab599FleetEnabledKey = @"TX500_FamilyFleetPresenceEnabled";
static NSInteger const Lab599FleetSchemaVersion = 1;

@interface Lab599FamilyFleet ()
@property(nonatomic, copy) NSString *deviceID;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) NSISO8601DateFormatter *dateFormatter;
@end

@implementation Lab599FamilyFleet

+ (instancetype)sharedFleet {
    static Lab599FamilyFleet *fleet;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ fleet = [Lab599FamilyFleet new]; });
    return fleet;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    NSString *storedID = [NSUserDefaults.standardUserDefaults stringForKey:@"TX500_FamilyFleetDeviceID"];
    NSUUID *validID = storedID ? [[NSUUID alloc] initWithUUIDString:storedID] : nil;
    self.deviceID = (validID ?: NSUUID.UUID).UUIDString;
    [NSUserDefaults.standardUserDefaults setObject:self.deviceID forKey:@"TX500_FamilyFleetDeviceID"];
    self.dateFormatter = [NSISO8601DateFormatter new];
    self.dateFormatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return self;
}

- (BOOL)isEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:Lab599FleetEnabledKey];
}

- (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:Lab599FleetEnabledKey];
    [self refreshFromPreferences];
}

- (NSURL *)cloudFamilyRoot {
    NSString *cloudDocsPath = [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Mobile Documents/com~apple~CloudDocs"] stringByStandardizingPath];
    BOOL isDirectory = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:cloudDocsPath isDirectory:&isDirectory] || !isDirectory) return nil;
    return [[NSURL fileURLWithPath:cloudDocsPath isDirectory:YES] URLByAppendingPathComponent:@"Radio-Utility-Family" isDirectory:YES];
}

- (void)refreshFromPreferences {
    NSAssert(NSThread.isMainThread, @"Family fleet timer is controlled on the main thread.");
    if (!self.isEnabled) {
        [self.timer invalidate];
        self.timer = nil;
        [self removeOwnHeartbeat];
        return;
    }
    if (!self.timer) {
        [self publishHeartbeatAndProcessStatusRequests];
        self.timer = [NSTimer scheduledTimerWithTimeInterval:15.0 target:self
            selector:@selector(publishHeartbeatAndProcessStatusRequests)
            userInfo:nil repeats:YES];
    }
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self removeOwnHeartbeat];
}

- (NSString *)liveStatusSummary {
    NSURL *root = [self cloudFamilyRoot];
    if (!root) return @"iCloud Drive is not available on this Mac. No local-only fleet data is used.";
    NSURL *folder = [root URLByAppendingPathComponent:@"family-fleet/presence" isDirectory:YES];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:folder
        includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSURL *url in files) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (!size || size.unsignedIntegerValue > 32768) continue;
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        NSDictionary *item = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![item isKindOfClass:NSDictionary.class] || [item[@"schemaVersion"] integerValue] != Lab599FleetSchemaVersion ||
            ![item[@"appRunning"] boolValue] || ![item[@"heartbeatAt"] isKindOfClass:NSString.class]) continue;
        NSDate *heartbeat = [self.dateFormatter dateFromString:item[@"heartbeatAt"]];
        NSTimeInterval age = heartbeat ? -heartbeat.timeIntervalSinceNow : DBL_MAX;
        if (!heartbeat || age < 0 || age > 45) continue;
        [lines addObject:[NSString stringWithFormat:@"%@ · %@ %@ (%@) · %@ · %lds ago",
            item[@"deviceName"] ?: @"Mac Station", item[@"applicationName"] ?: @"Radio Utility",
            item[@"applicationVersion"] ?: @"?", item[@"applicationBuild"] ?: @"?",
            item[@"radioState"] ?: @"unverified", (long)age]];
    }
    if (!lines.count) return @"No recent family app heartbeats are visible. Confirm that presence is enabled on each Mac and iCloud Drive has synchronized.";
    [lines sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    return [lines componentsJoinedByString:@"\n"];
}

- (void)removeOwnHeartbeat {
    NSURL *folder = [[self cloudFamilyRoot] URLByAppendingPathComponent:@"family-fleet/presence" isDirectory:YES];
    NSURL *record = [folder URLByAppendingPathComponent:[self.deviceID stringByAppendingString:@".json"]];
    [NSFileManager.defaultManager removeItemAtURL:record error:nil];
}

- (void)publishHeartbeatAndProcessStatusRequests {
    if (!self.isEnabled) return;
    NSURL *root = [self cloudFamilyRoot];
    if (!root) return;
    NSURL *presenceFolder = [root URLByAppendingPathComponent:@"family-fleet/presence" isDirectory:YES];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:presenceFolder withIntermediateDirectories:YES attributes:nil error:&error]) return;

    NSBundle *bundle = NSBundle.mainBundle;
    NSString *model = [NSUserDefaults.standardUserDefaults stringForKey:@"TX500_StationRig"] ?: @"Lab599 Discovery TX-500";
    NSDictionary *record = @{
        @"schemaVersion": @(Lab599FleetSchemaVersion),
        @"deviceID": self.deviceID,
        @"deviceName": NSHost.currentHost.localizedName ?: @"Mac Station",
        @"applicationID": @"lab599-utility",
        @"applicationName": @"Lab599 Utility",
        @"applicationVersion": [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
        @"applicationBuild": [bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
        @"radioModel": model,
        @"appRunning": @YES,
        @"acceptsRemoteCommands": @NO,
        @"radioState": @"unverified",
        @"receiving": @NO,
        @"heartbeatAt": [self.dateFormatter stringFromDate:NSDate.date]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:&error];
    NSURL *recordURL = [presenceFolder URLByAppendingPathComponent:[self.deviceID stringByAppendingString:@".json"]];
    if (data) [data writeToURL:recordURL options:NSDataWritingAtomic error:nil];
    [self processStatusRequestsAtRoot:root];
}

- (void)processStatusRequestsAtRoot:(NSURL *)root {
    NSURL *inbox = [[root URLByAppendingPathComponent:@"family-fleet/commands/inbox" isDirectory:YES]
        URLByAppendingPathComponent:self.deviceID isDirectory:YES];
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:inbox
        includingPropertiesForKeys:@[NSURLFileSizeKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    if (!files.count) return;
    NSURL *results = [root URLByAppendingPathComponent:@"family-fleet/commands/results" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:results withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSURL *url in files) {
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        if (![url.pathExtension isEqualToString:@"json"] || !size || size.unsignedIntegerValue > 32768) continue;
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        NSDictionary *request = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![request isKindOfClass:NSDictionary.class] || [request[@"schemaVersion"] integerValue] != Lab599FleetSchemaVersion ||
            ![request[@"targetDeviceID"] isEqual:self.deviceID] || ![request[@"id"] isKindOfClass:NSString.class]) continue;
        NSDate *issued = [self.dateFormatter dateFromString:request[@"issuedAt"] ?: @""];
        NSDate *expires = [self.dateFormatter dateFromString:request[@"expiresAt"] ?: @""];
        if (!issued || !expires || expires.timeIntervalSinceNow < 0 || issued.timeIntervalSinceNow > 30 || issued.timeIntervalSinceNow < -60) continue;
        NSString *requestID = request[@"id"];
        NSURL *resultURL = [results URLByAppendingPathComponent:[requestID stringByAppendingString:@".json"]];
        if ([NSFileManager.defaultManager fileExistsAtPath:resultURL.path]) continue;
        NSString *command = [request[@"command"] isKindOfClass:NSString.class] ? request[@"command"] : @"";
        BOOL isStatusRequest = [command isEqualToString:@"requestStatus"];
        NSDictionary *response = @{
            @"schemaVersion": @(Lab599FleetSchemaVersion),
            @"id": NSUUID.UUID.UUIDString,
            @"requestID": requestID,
            @"senderDeviceID": request[@"senderDeviceID"] ?: @"",
            @"targetDeviceID": self.deviceID,
            @"command": command,
            @"completedAt": [self.dateFormatter stringFromDate:NSDate.date],
            @"accepted": @(isStatusRequest),
            @"summary": isStatusRequest ? @"Lab599 Utility is running · CAT status unverified." : @"This application does not accept remote radio or automation commands."
        };
        NSData *responseData = [NSJSONSerialization dataWithJSONObject:response options:NSJSONWritingSortedKeys error:nil];
        if (responseData && [responseData writeToURL:resultURL options:NSDataWritingAtomic error:nil]) {
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
    }
}

@end
