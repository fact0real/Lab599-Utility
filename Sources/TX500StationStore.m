#import "TX500StationStore.h"
#import <math.h>
NSString *const TXStationStoreChanged=@"TXStationStoreChanged";
static NSError *StoreError(NSString *s) { return [NSError errorWithDomain:@"TXStationStore" code:1 userInfo:@{NSLocalizedDescriptionKey:s}]; }
static BOOL Matches(NSString *s,NSString *pattern) { return [s rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound; }
static NSDictionary *LegacyKeys(void) { return @{@"call":@"TX500_OperatorCallsign",@"grid":@"TX500_OperatorGrid",@"operatorName":@"TX500_OperatorName",@"rig":@"TX500_StationRig",@"antenna":@"TX500_StationAntenna"}; }
@implementation TX500StationStore {
    NSURL *_URL; NSUserDefaults *_defaults; NSMutableDictionary *_data; BOOL _publishing;
}
+ (instancetype)sharedStore { static id store; static dispatch_once_t once; dispatch_once(&once, ^{
    NSString *override=NSProcessInfo.processInfo.environment[@"TX500_STATION_TEST_ROOT"];
    NSURL *root=override.length ? [NSURL fileURLWithPath:override] : [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    store=[[self alloc] initWithURL:[root URLByAppendingPathComponent:@"Lab599 Utility/Station/station.json"] defaults:NSUserDefaults.standardUserDefaults];
}); return store; }
- (instancetype)initWithURL:(NSURL *)URL defaults:(NSUserDefaults *)defaults {
    if((self=[super init])) {
        _URL=URL; _defaults=defaults;
        NSData *raw=[NSData dataWithContentsOfURL:URL]; NSDictionary *saved=raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
        if(raw && (![saved isKindOfClass:NSDictionary.class] || (![saved[@"version"] isKindOfClass:NSNumber.class] || [saved[@"version"] integerValue]!=1) || ![saved[@"profiles"] isKindOfClass:NSArray.class] || ![saved[@"frequencies"] isKindOfClass:NSArray.class] || ![saved[@"shortcuts"] isKindOfClass:NSDictionary.class] || ![saved[@"active"] isKindOfClass:NSString.class])) _loadError=StoreError(@"Station data could not be loaded. The original file was preserved; restore it before saving.");
        if(saved && !_loadError) {
            for(id p in saved[@"profiles"]) if(![p isKindOfClass:NSDictionary.class] || ![p[@"id"] isKindOfClass:NSString.class] || ![p[@"name"] isKindOfClass:NSString.class]) _loadError=StoreError(@"Invalid profile data; original file preserved.");
            for(id f in saved[@"frequencies"]) if(![f isKindOfClass:NSDictionary.class] || ![f[@"id"] isKindOfClass:NSString.class] || ![f[@"name"] isKindOfClass:NSString.class] || ![f[@"hz"] isKindOfClass:NSNumber.class]) _loadError=StoreError(@"Invalid frequency data; original file preserved.");
        }
        if(saved && !_loadError) {
            for(NSDictionary *p in saved[@"profiles"]) for(id value in p.allValues) if(![value isKindOfClass:NSString.class]) _loadError=StoreError(@"Invalid profile field type; original file preserved.");
            for(NSDictionary *f in saved[@"frequencies"]) if(![f[@"mode"] isKindOfClass:NSNumber.class] || (f[@"tags"] && ![f[@"tags"] isKindOfClass:NSString.class])) _loadError=StoreError(@"Invalid frequency field type; original file preserved.");
            for(id value in [saved[@"shortcuts"] allValues]) if(![value isKindOfClass:NSString.class]) _loadError=StoreError(@"Invalid shortcut field type; original file preserved.");
        }
        if(saved && !_loadError) {
            NSMutableSet *ids=[NSMutableSet set];
            for(NSDictionary *p in saved[@"profiles"]) {
                if(![p[@"id"] length] || ![p[@"name"] length] || [ids containsObject:p[@"id"]]) _loadError=StoreError(@"Invalid or duplicate station profile; original file preserved.");
                [ids addObject:p[@"id"]];
            }
            if(![ids containsObject:saved[@"active"]]) _loadError=StoreError(@"Active station profile is missing; original file preserved.");
            for(NSDictionary *f in saved[@"frequencies"]) {
                if([f[@"hz"] doubleValue]<500000 || [f[@"hz"] doubleValue]>56000000 || ![@[@1,@2,@3,@4,@5,@6,@7,@9] containsObject:f[@"mode"]] || (f[@"favorite"] && ![f[@"favorite"] isKindOfClass:NSNumber.class])) _loadError=StoreError(@"Invalid frequency value; original file preserved.");
            }
        }
        if(saved && !_loadError) _data=[saved mutableCopy];
        else {
            NSMutableDictionary *p=[@{@"id":NSUUID.UUID.UUIDString,@"name":@"Home station",@"region":@"1",@"rig":@"Lab599 TX-500"} mutableCopy];
            [LegacyKeys() enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *legacy,BOOL *stop) { (void)stop; NSString *v=[defaults stringForKey:legacy]; if(v.length) p[key]=v; }];
            p[@"operatorCall"]=p[@"call"] ?: @"";
            NSMutableArray *frequencies=[NSMutableArray array];
            NSArray *presets=@[@[@"40m · FT8",@7074000,@6,@"Digital"],@[@"20m · FT8",@14074000,@6,@"Digital"],@[@"20m · SSB QRP",@14285000,@2,@"Voice"],@[@"40m · CW QRP",@7030000,@3,@"CW"],@[@"20m · CW QRP",@14060000,@3,@"CW"]];
            for(NSArray *x in presets) [frequencies addObject:@{@"id":NSUUID.UUID.UUIDString,@"name":x[0],@"hz":x[1],@"mode":x[2],@"tags":x[3],@"favorite":@YES}];
            _data=[@{@"version":@1,@"active":p[@"id"],@"profiles":@[p],@"frequencies":frequencies,@"shortcuts":@{@"station":@"1",@"read":@"r",@"favorite":@"d",@"voice":@"2",@"cw":@"3",@"digital":@"4"}} mutableCopy];
        }
    } return self;
}
- (NSArray *)profiles { return _data[@"profiles"]; }
- (NSDictionary *)activeProfile { for(NSDictionary *p in self.profiles) if([p[@"id"] isEqual:_data[@"active"]]) return p; return self.profiles.firstObject ?: @{}; }
- (NSArray *)frequencies { return _data[@"frequencies"]; }
- (NSDictionary *)shortcuts { return _data[@"shortcuts"]; }
- (BOOL)commit:(NSMutableDictionary *)next error:(NSError **)error {
    if(_loadError) { if(error) *error=_loadError; return NO; }
    if(![NSFileManager.defaultManager createDirectoryAtURL:_URL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSData *json=[NSJSONSerialization dataWithJSONObject:next options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    if(!json || ![json writeToURL:_URL options:NSDataWritingAtomic error:error]) return NO;
    NSDictionary *previous=self.activeProfile; _data=next;
    BOOL identityChanged=![previous isEqual:self.activeProfile] || ![[_defaults dictionaryForKey:@"TX500_ActiveStationProfile"] isEqual:self.activeProfile];
    if(identityChanged) [self publish]; else [NSNotificationCenter.defaultCenter postNotificationName:TXStationStoreChanged object:self]; return YES;
}
- (void)publish {
    _publishing=YES; NSDictionary *p=self.activeProfile;
    [LegacyKeys() enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *legacy,BOOL *stop) { (void)stop; [self->_defaults setObject:p[key] ?: @"" forKey:legacy]; }];
    [_defaults setObject:p forKey:@"TX500_ActiveStationProfile"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TX500StationSettingsChangedNotification" object:self];
    [NSNotificationCenter.defaultCenter postNotificationName:TXStationStoreChanged object:self]; _publishing=NO;
}
- (BOOL)saveProfile:(NSDictionary *)profile activate:(BOOL)activate error:(NSError **)error {
    NSMutableDictionary *p=[profile mutableCopy];
    for(NSString *key in @[@"name",@"call",@"operatorCall",@"grid",@"operatorName",@"rig",@"antenna",@"country",@"city",@"state",@"county",@"cqZone",@"ituZone",@"iota",@"sig",@"sigInfo",@"region",@"radioInput",@"radioOutput",@"microphone",@"headphones"]) {
        id v=p[key]; if(v && ![v isKindOfClass:NSString.class]) { if(error) *error=StoreError(@"Profile fields must be text."); return NO; }
        NSString *s=[(v ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if([s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>254) { if(error) *error=StoreError(@"Profile fields must be shorter than 255 characters."); return NO; } p[key]=s;
    }
    for(NSString *key in @[@"call",@"operatorCall",@"grid",@"iota",@"sig"]) p[key]=[p[key] uppercaseString];
    NSString *why=nil;
    if(![p[@"name"] length]) why=@"Name the station profile.";
    for(NSString *key in @[@"call",@"operatorCall"]) if([p[key] length] && (!Matches(p[key],@"^[A-Z0-9]+(/[A-Z0-9]+)*$") || !Matches(p[key],@"[0-9]") || !Matches(p[key],@"[A-Z]"))) why=@"Enter a callsign using letters, digits and optional slash suffixes.";
    if([p[@"grid"] length] && !Matches(p[@"grid"],@"^[A-R]{2}[0-9]{2}([A-X]{2}([0-9]{2})?)?$")) why=@"Grid must be a valid 4, 6 or 8 character Maidenhead locator.";
    if(![@[@"1",@"2",@"3"] containsObject:p[@"region"]]) why=@"Choose IARU region 1, 2 or 3.";
    for(NSString *key in @[@"cqZone",@"ituZone"]) if([p[key] length] && (!Matches(p[key],@"^[0-9]{1,2}$") || [p[key] integerValue]<1 || [p[key] integerValue]>([key isEqual:@"cqZone"]?40:90))) why=@"CQ zone must be 1–40; ITU zone must be 1–90.";
    if(why) { if(error) *error=StoreError(why); return NO; }
    if(![p[@"id"] isKindOfClass:NSString.class] || ![p[@"id"] length]) p[@"id"]=NSUUID.UUID.UUIDString;
    NSMutableArray *all=[self.profiles mutableCopy]; NSUInteger index=[all indexOfObjectPassingTest:^BOOL(NSDictionary *x,NSUInteger i,BOOL *stop) { (void)i;(void)stop;return [x[@"id"] isEqual:p[@"id"]]; }];
    if(index==NSNotFound) [all addObject:p]; else all[index]=p;
    NSMutableDictionary *next=[_data mutableCopy]; next[@"profiles"]=all; if(activate) next[@"active"]=p[@"id"]; return [self commit:next error:error];
}
- (BOOL)activateProfile:(NSString *)identifier error:(NSError **)error { for(NSDictionary *p in self.profiles) if([p[@"id"] isEqual:identifier]) { NSMutableDictionary *next=[_data mutableCopy]; next[@"active"]=identifier; return [self commit:next error:error]; } if(error) *error=StoreError(@"Profile not found."); return NO; }
- (BOOL)removeProfile:(NSString *)identifier error:(NSError **)error {
    if(self.profiles.count<2 || [self.activeProfile[@"id"] isEqual:identifier]) { if(error) *error=StoreError(@"Keep the active profile. Select another profile before removing this one."); return NO; }
    NSMutableArray *all=[self.profiles mutableCopy]; NSIndexSet *indices=[all indexesOfObjectsPassingTest:^BOOL(NSDictionary *p,NSUInteger i,BOOL *stop) { (void)i;(void)stop; return [p[@"id"] isEqual:identifier]; }]; [all removeObjectsAtIndexes:indices]; NSMutableDictionary *next=[_data mutableCopy]; next[@"profiles"]=all; return [self commit:next error:error];
}
- (void)captureLegacySettings { if(_publishing || _loadError) return; NSMutableDictionary *p=[self.activeProfile mutableCopy]; BOOL changed=NO; for(NSString *key in LegacyKeys()) { NSString *v=[_defaults stringForKey:LegacyKeys()[key]] ?: @""; if(![v isEqual:p[key] ?: @""]) { p[key]=v; changed=YES; } } if(changed) [self saveProfile:p activate:YES error:nil]; }
+ (BOOL)parseMHz:(NSString *)text hertz:(uint64_t *)hz { NSScanner *s=[NSScanner scannerWithString:text]; s.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; double v=0; if(![s scanDouble:&v] || !s.isAtEnd || !isfinite(v) || v<0.5 || v>56) return NO; if(hz) *hz=(uint64_t)llround(v*1e6); return YES; }
- (BOOL)saveFrequency:(NSDictionary *)entry error:(NSError **)error {
    if(![entry[@"name"] isKindOfClass:NSString.class] || ![entry[@"name"] length] || [entry[@"name"] length]>100 || ![entry[@"hz"] isKindOfClass:NSNumber.class] || [entry[@"hz"] unsignedLongLongValue]<500000 || [entry[@"hz"] unsignedLongLongValue]>56000000 || ![@[@1,@2,@3,@4,@5,@6,@7,@9] containsObject:entry[@"mode"]]) { if(error) *error=StoreError(@"Enter a name, valid mode and frequency from 0.5 to 56 MHz."); return NO; }
    NSMutableDictionary *f=[entry mutableCopy]; if(![f[@"id"] isKindOfClass:NSString.class]) f[@"id"]=NSUUID.UUID.UUIDString;
    f[@"tags"]=[f[@"tags"] isKindOfClass:NSString.class] ? f[@"tags"] : @"";
    NSMutableArray *all=[self.frequencies mutableCopy]; NSUInteger idx=[all indexOfObjectPassingTest:^BOOL(NSDictionary *x,NSUInteger i,BOOL *stop){(void)i;(void)stop;return [x[@"id"] isEqual:f[@"id"]];}];
    if(idx==NSNotFound) [all addObject:f]; else all[idx]=f; NSMutableDictionary *next=[_data mutableCopy]; next[@"frequencies"]=all; return [self commit:next error:error];
}
- (BOOL)removeFrequency:(NSString *)identifier error:(NSError **)error { NSMutableArray *all=[self.frequencies mutableCopy]; NSIndexSet *indices=[all indexesOfObjectsPassingTest:^BOOL(NSDictionary *f,NSUInteger i,BOOL *stop){(void)i;(void)stop;return [f[@"id"] isEqual:identifier];}]; [all removeObjectsAtIndexes:indices]; NSMutableDictionary *next=[_data mutableCopy]; next[@"frequencies"]=all; return [self commit:next error:error]; }
- (BOOL)setShortcut:(NSString *)key command:(NSString *)command error:(NSError **)error {
    NSMutableDictionary *all=[self.shortcuts mutableCopy]; if(!all[command]) { if(error) *error=StoreError(@"Unknown command."); return NO; }
    all[command]=key.lowercaseString; return [self saveShortcuts:all error:error];
}
- (BOOL)saveShortcuts:(NSDictionary *)shortcuts error:(NSError **)error {
    if(![[NSSet setWithArray:shortcuts.allKeys] isEqual:[NSSet setWithArray:self.shortcuts.allKeys]]) { if(error) *error=StoreError(@"Unknown shortcut commands."); return NO; }
    NSMutableDictionary *all=[NSMutableDictionary dictionary]; NSMutableSet *used=[NSMutableSet set];
    for(NSString *command in shortcuts) {
        id value=shortcuts[command]; if(![value isKindOfClass:NSString.class]) { if(error) *error=StoreError(@"Shortcut keys must be text."); return NO; }
        NSString *key=[value lowercaseString];
        if(key.length && (!Matches(key,@"^[a-z0-9]$") || [used containsObject:key])) { if(error) *error=StoreError(@"Use a unique letter or digit for each Command–Option shortcut."); return NO; }
        if(key.length) [used addObject:key]; all[command]=key;
    }
    NSMutableDictionary *next=[_data mutableCopy]; next[@"shortcuts"]=all; return [self commit:next error:error];
}
+ (NSArray *)bandSegments {
    static NSArray *data; static dispatch_once_t once; dispatch_once(&once, ^{
        // Factual segment boundaries from IARU Region 1 HF plan, effective 2020-10-16.
        // Upper endpoints are exclusive. This reference is not a national TX authorization.
        NSArray *rows=@[
        @[@1810,@1838,@200,@"CW"],@[@1838,@1840,@500,@"Narrow digital"],@[@1840,@1843,@2700,@"Digital / all modes"],@[@1843,@2000,@2700,@"All modes"],
        @[@3500,@3570,@200,@"CW"],@[@3570,@3580,@200,@"Narrow digital"],@[@3580,@3600,@500,@"Narrow digital"],@[@3600,@3800,@2700,@"All modes"],
        @[@5351.5,@5354,@200,@"CW / narrow digital"],@[@5354,@5366,@2700,@"All modes • USB voice"],@[@5366,@5366.5,@20,@"Weak-signal digital"],
        @[@7000,@7040,@200,@"CW"],@[@7040,@7050,@500,@"Narrow digital"],@[@7050,@7060,@2700,@"Digital / all modes"],@[@7060,@7200,@2700,@"All modes"],
        @[@10100,@10130,@200,@"CW"],@[@10130,@10150,@500,@"Narrow digital"],
        @[@14000,@14070,@200,@"CW"],@[@14070,@14099,@500,@"Narrow digital"],@[@14099,@14101,@0,@"Beacons only"],@[@14101,@14112,@2700,@"Digital / all modes"],@[@14112,@14350,@2700,@"All modes"],
        @[@18068,@18095,@200,@"CW"],@[@18095,@18109,@500,@"Narrow digital"],@[@18109,@18111,@0,@"Beacons only"],@[@18111,@18120,@2700,@"Digital / all modes"],@[@18120,@18168,@2700,@"All modes"],
        @[@21000,@21070,@200,@"CW"],@[@21070,@21110,@500,@"Narrow digital"],@[@21110,@21120,@2700,@"Digital • no SSB"],@[@21120,@21149,@500,@"Narrow digital"],@[@21149,@21151,@0,@"Beacons only"],@[@21151,@21450,@2700,@"All modes"],
        @[@24890,@24915,@200,@"CW"],@[@24915,@24929,@500,@"Narrow digital"],@[@24929,@24931,@0,@"Beacons only"],@[@24931,@24940,@2700,@"Digital / all modes"],@[@24940,@24990,@2700,@"All modes"],
        @[@28000,@28070,@200,@"CW"],@[@28070,@28190,@500,@"Narrow digital"],@[@28190,@28225,@0,@"Beacons only"],@[@28225,@28300,@2700,@"Beacons"],@[@28300,@28320,@2700,@"Digital / all modes"],@[@28320,@29000,@2700,@"All modes"],@[@29000,@29300,@0,@"All modes"],@[@29300,@29510,@0,@"Satellite links"],@[@29510,@29520,@0,@"Guard channel"],@[@29520,@29590,@6000,@"FM repeater input"],@[@29620,@29700,@6000,@"FM repeater output"]];
        NSMutableArray *result=[NSMutableArray array]; for(NSArray *r in rows) [result addObject:@{@"low":@([r[0] doubleValue]*1000),@"high":@([r[1] doubleValue]*1000),@"bandwidth":r[2],@"usage":r[3]}]; data=result;
    }); return data;
}
+ (NSArray *)segmentsAt:(uint64_t)hz { return [[self bandSegments] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s,NSDictionary *b){(void)b;return hz>=[s[@"low"] unsignedLongLongValue] && hz<[s[@"high"] unsignedLongLongValue];}]]; }
@end
