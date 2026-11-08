#import "RadioFamilySupport.h"
#import "TX500SecretStore.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

@interface RadioFamilySupport ()
@property(nonatomic,strong) NSWindow *window;
@property(nonatomic,strong) NSButton *sharing;
@property(nonatomic,strong) NSButton *credentialSharing;
@property(nonatomic,strong) NSPopUpButton *sources;
@property(nonatomic,strong) NSTextField *preview;
@property(nonatomic,strong) NSTextField *status;
@property(nonatomic,strong) NSArray<NSDictionary *> *snapshots;
@end
@implementation RadioFamilySupport
+ (instancetype)shared { static RadioFamilySupport *x; static dispatch_once_t once; dispatch_once(&once, ^{ x=[self new]; }); return x; }
+ (NSURL *)rootURL {
#ifdef RADIO_FAMILY_TESTING
    const char *root=getenv("RADIO_FAMILY_TEST_ROOT");
    if(root) return [NSURL fileURLWithPath:[NSString stringWithUTF8String:root] isDirectory:YES];
#endif
    return [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Radio-Utility-Family" isDirectory:YES];
}
+ (NSDictionary *)identity {
    NSBundle *b=NSBundle.mainBundle;
    return @{ @"appID":@"lab599-utility", @"appName":@"Lab599 Utility", @"bundleID":b.bundleIdentifier ?: @"development",
              @"appVersion":[b objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"development",
              @"appBuild":[b objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"development" };
}
+ (dispatch_queue_t)writerQueue { static dispatch_queue_t q; static dispatch_once_t once; dispatch_once(&once, ^{ q=dispatch_queue_create("ir.factoreal.radiofamily.diagnostics",DISPATCH_QUEUE_SERIAL); }); return q; }
+ (NSString *)runID { static NSString *run; static dispatch_once_t once; dispatch_once(&once, ^{ run=NSUUID.UUID.UUIDString; }); return run; }
+ (NSString *)timestamp { NSISO8601DateFormatter *f=[NSISO8601DateFormatter new]; f.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds; return [f stringFromDate:NSDate.date]; }
+ (void)recordEvent:(NSString *)event details:(NSDictionary *)details {
#ifndef RADIO_FAMILY_TESTING
    if (![NSBundle.mainBundle.bundleURL.pathExtension isEqual:@"app"]) return;
#endif
    NSDictionary *snapshot=[details copy]; NSString *kind=[event copy];
    dispatch_async(self.writerQueue, ^{
        NSMutableDictionary *record=[snapshot mutableCopy];
        [record addEntriesFromDictionary:self.identity];
        NSString *stamp=self.timestamp;
        [record addEntriesFromDictionary:@{@"schemaVersion":@1,@"event":kind,@"runID":self.runID,@"channel":@"operations",@"writtenAtUTC":stamp}];
        record[@"eventID"]=NSUUID.UUID.UUIDString;
        record[@"processID"]=@(NSProcessInfo.processInfo.processIdentifier);
        record[@"monotonicUptimeSeconds"]=@(NSProcessInfo.processInfo.systemUptime);
        if(!record[@"timestampUTC"]) record[@"timestampUTC"]=stamp;
        NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil]; if(!data) return;
        NSURL *folder=[[[self.rootURL URLByAppendingPathComponent:@"Logs"] URLByAppendingPathComponent:@"lab599-utility"] URLByAppendingPathComponent:[stamp substringToIndex:10]];
        NSError *error=nil;
        if(![NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]) return;
        static NSString *currentDay; static NSUInteger segment=0, segmentBytes=0;
        NSString *day=[stamp substringToIndex:10];
        if(![day isEqual:currentDay]) { currentDay=day; segment=0; segmentBytes=0; }
        if(segmentBytes>0 && segmentBytes+data.length+1>8*1024*1024) { segment++; segmentBytes=0; }
        NSURL *url=[folder URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-operations-%04lu.jsonl",self.runID,(unsigned long)segment]];
        int fd=open(url.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND|O_NOFOLLOW,0600); if(fd<0) return;
        NSMutableData *line=[data mutableCopy]; [line appendBytes:"\n" length:1];
        const char *bytes=line.bytes; size_t remaining=line.length;
        while(remaining) { ssize_t n=write(fd,bytes,remaining); if(n<0&&errno==EINTR) continue; if(n<=0) break; bytes+=n; remaining-=(size_t)n; }
        close(fd);
        segmentBytes+=line.length-remaining;
    });
}
+ (void)flushDiagnostics { dispatch_sync(self.writerQueue,^{}); }
+ (void)showSettings { [[self shared] openWindow]; }
- (NSButton *)button:(NSString *)title action:(SEL)action { return [NSButton buttonWithTitle:title target:self action:action]; }
- (void)openWindow {
    if(!self.window) {
        self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,650,650) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.window.title=@"Radio Utility Family"; self.window.releasedWhenClosed=NO;
        NSStackView *stack=[NSStackView new]; stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.alignment=NSLayoutAttributeLeading; stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=NO;
        NSScrollView *scroll=[NSScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO;
        scroll.hasVerticalScroller=YES; scroll.autohidesScrollers=YES; scroll.drawsBackground=NO;
        [self.window.contentView addSubview:scroll];
        NSView *document=[NSView new]; document.translatesAutoresizingMaskIntoConstraints=NO;
        scroll.documentView=document; [document addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [scroll.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor],
            [scroll.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor],
            [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
            [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-20],
            [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:20],
            [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20]]];
        NSTextField *intro=[NSTextField wrappingLabelWithString:@"New diagnostics from all four utilities use one family folder, with app name, version, build and run in every record. Existing diagnostic and contact logs are preserved."]; [stack addArrangedSubview:intro];
        NSStackView *logs=[NSStackView stackViewWithViews:@[[self button:@"Open family logs" action:@selector(openLogs:)],[self button:@"Export all family logs…" action:@selector(exportLogs:)]]]; [stack addArrangedSubview:logs];
        self.sharing=[NSButton checkboxWithTitle:@"Allow sharing and importing station identity" target:self action:@selector(sharingChanged:)]; self.sharing.state=[NSUserDefaults.standardUserDefaults boolForKey:@"radio.family.settingsSharing.enabled"] ? NSControlStateValueOn:NSControlStateValueOff; [stack addArrangedSubview:self.sharing];
        [stack addArrangedSubview:[NSTextField wrappingLabelWithString:@"Only callsign, locator, operator name, city, CQ/ITU zones and IOTA are portable. Radio commands, CAT and audio routes, power, transmit permissions, credentials and contacts stay separate."]];
        NSStackView *actions=[NSStackView stackViewWithViews:@[[self button:@"Share this app’s station settings" action:@selector(publish:)],[self button:@"Refresh available apps" action:@selector(refresh:)]]]; [stack addArrangedSubview:actions];
        self.sources=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; self.sources.target=self; self.sources.action=@selector(selectSource:); [stack addArrangedSubview:self.sources];
        self.preview=[NSTextField wrappingLabelWithString:@"Choose an app to preview its station settings."]; self.preview.selectable=YES; [stack addArrangedSubview:self.preview];
        [stack addArrangedSubview:[self button:@"Import the previewed station settings" action:@selector(import:)]];
        self.credentialSharing=[NSButton checkboxWithTitle:@"Allow explicit credential sharing through macOS Keychain" target:self action:@selector(credentialSharingChanged:)];
        self.credentialSharing.state=[NSUserDefaults.standardUserDefaults boolForKey:@"radio.family.credentialSharing.enabled"]?NSControlStateValueOn:NSControlStateValueOff; [stack addArrangedSubview:self.credentialSharing];
        [stack addArrangedSubview:[NSStackView stackViewWithViews:@[[self button:@"Publish saved service credentials" action:@selector(publishCredentials:)],[self button:@"Import credentials from selected app" action:@selector(importCredentials:)]]]];
        self.status=[NSTextField wrappingLabelWithString:@""]; self.status.selectable=YES; [stack addArrangedSubview:self.status];
        for(NSView *v in stack.arrangedSubviews) [v.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor].active=YES;
        [self.window center];
    }
    [self refresh:nil]; [self.window makeKeyAndOrderFront:nil];
}
- (BOOL)enabled { return [NSUserDefaults.standardUserDefaults boolForKey:@"radio.family.settingsSharing.enabled"]; }
- (NSURL *)settingsURL { return [[RadioFamilySupport.rootURL URLByAppendingPathComponent:@"Settings"] URLByAppendingPathComponent:@"lab599-utility.json"]; }
- (void)sharingChanged:(id)sender {
    [NSUserDefaults.standardUserDefaults setBool:self.sharing.state==NSControlStateValueOn forKey:@"radio.family.settingsSharing.enabled"];
    if(!self.enabled) {
        [NSFileManager.defaultManager removeItemAtURL:self.settingsURL error:nil];
        self.credentialSharing.state=NSControlStateValueOff; [self credentialSharingChanged:nil];
    }
    [self refresh:nil];
}
+ (NSDictionary *)settingMap { return @{@"station.callsign":@"TX500_OperatorCallsign",@"station.grid":@"TX500_OperatorGrid",@"station.operatorName":@"TX500_OperatorName"}; }
+ (BOOL)validValues:(NSDictionary *)values {
    if(![values isKindOfClass:NSDictionary.class] || values.count>7) return NO;
    NSSet *allowed=[NSSet setWithArray:@[@"station.callsign",@"station.grid",@"station.operatorName",@"station.qthCity",@"station.cqZone",@"station.ituZone",@"station.iota"]];
    for(id key in values) { id value=values[key]; if(![allowed containsObject:key]||![value isKindOfClass:NSString.class]||[value length]>160||[value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound) return NO; }
    NSString *call=values[@"station.callsign"];
    if(call.length && (![call isEqualToString:call.uppercaseString] || call.length<3 || call.length>24 || [call rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/"] invertedSet]].location!=NSNotFound || [call rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location==NSNotFound || [call rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location==NSNotFound)) return NO;
    NSString *grid=values[@"station.grid"];
    if(grid.length && [grid rangeOfString:@"^[A-R]{2}[0-9]{2}([A-X]{2})?$" options:NSRegularExpressionSearch].location==NSNotFound) return NO;
    for(NSString *key in @[@"station.cqZone",@"station.ituZone"]) if([values[key] length]) { NSInteger n=[values[key] integerValue]; if(n<1 || n>([key isEqual:@"station.cqZone"]?40:90) || ![[NSString stringWithFormat:@"%ld",(long)n] isEqual:values[key]]) return NO; }
    return YES;
}
- (void)publish:(id)sender {
    if(!self.enabled) { self.status.stringValue=@"Enable station sharing first."; return; }
    NSMutableDictionary *values=[NSMutableDictionary new];
    [RadioFamilySupport.settingMap enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *local,BOOL *stop){ values[key]=[NSUserDefaults.standardUserDefaults stringForKey:local] ?: @""; }];
    NSDictionary *profile=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TX500_ActiveStationProfile"] ?: @{};
    for(NSString *key in @[@"city",@"cqZone",@"ituZone",@"iota"]) { NSString *target=[key isEqual:@"city"]?@"qthCity":key; id v=profile[key]; if(v) values[[@"station." stringByAppendingString:target]]=[v description]; }
    if(![RadioFamilySupport validValues:values]) { self.status.stringValue=@"Correct the station callsign, locator or zones before sharing."; return; }
    NSDictionary *snapshot=@{@"schemaVersion":@1,@"source":RadioFamilySupport.identity,@"updatedAtUTC":RadioFamilySupport.timestamp,@"values":values};
    NSError *error=nil; [NSFileManager.defaultManager createDirectoryAtURL:self.settingsURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error];
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:&error];
    if(data && [data writeToURL:self.settingsURL options:NSDataWritingAtomic error:&error]) { [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:self.settingsURL.path error:nil]; self.status.stringValue=@"Shared station settings. Other apps must opt in before importing."; }
    else self.status.stringValue=error.localizedDescription ?: @"Could not share station settings.";
}
- (void)refresh:(id)sender {
    [self.sources removeAllItems]; self.snapshots=@[]; self.preview.stringValue=@"Choose an app to preview its station settings.";
    if(!self.enabled) return;
    NSMutableArray *snapshots=[NSMutableArray new]; NSURL *folder=[RadioFamilySupport.rootURL URLByAppendingPathComponent:@"Settings"];
    NSArray *urls=[NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:@[NSURLFileSizeKey,NSURLIsSymbolicLinkKey] options:0 error:nil];
    for(NSURL *url in urls) {
        if(![url.pathExtension isEqual:@"json"]||[url.lastPathComponent isEqual:@"lab599-utility.json"]) continue;
        NSDictionary *props=[url resourceValuesForKeys:@[NSURLFileSizeKey,NSURLIsSymbolicLinkKey] error:nil]; if([props[NSURLIsSymbolicLinkKey] boolValue]||[props[NSURLFileSizeKey] unsignedLongLongValue]>64000) continue;
        NSData *data=[NSData dataWithContentsOfURL:url]; NSDictionary *s=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        if(![s isKindOfClass:NSDictionary.class]||![s[@"schemaVersion"] isEqual:@1]||![s[@"source"] isKindOfClass:NSDictionary.class]||![RadioFamilySupport validValues:s[@"values"]]) continue;
        NSString *appID=s[@"source"][@"appID"]; if(![appID isKindOfClass:NSString.class]||![[appID stringByAppendingString:@".json"] isEqual:url.lastPathComponent]) continue;
        [snapshots addObject:s]; NSString *name=s[@"source"][@"appName"]; [self.sources addItemWithTitle:[name isKindOfClass:NSString.class]?name:appID];
    }
    self.snapshots=snapshots; [self selectSource:nil];
}
- (NSDictionary *)selected { NSInteger i=self.sources.indexOfSelectedItem; return i>=0 && (NSUInteger)i<self.snapshots.count ? self.snapshots[(NSUInteger)i]:nil; }
- (void)selectSource:(id)sender {
    NSDictionary *s=self.selected; if(!s) { self.preview.stringValue=@"No station settings are available from another app."; return; }
    NSMutableArray *rows=[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@ · %@ (%@)\nShared %@",s[@"source"][@"appName"],s[@"source"][@"appVersion"],s[@"source"][@"appBuild"],s[@"updatedAtUTC"]]];
    for(NSString *key in [s[@"values"] allKeys]) [rows addObject:[NSString stringWithFormat:@"%@: %@",key,s[@"values"][key]]]; self.preview.stringValue=[rows componentsJoinedByString:@"\n"];
}
- (void)import:(id)sender {
    NSDictionary *s=self.selected; if(!self.enabled||!s||![RadioFamilySupport validValues:s[@"values"]]) return;
    NSDictionary *values=s[@"values"];
    [RadioFamilySupport.settingMap enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *local,BOOL *stop){ if(values[key]) [NSUserDefaults.standardUserDefaults setObject:values[key] forKey:local]; }];
    NSMutableDictionary *profile=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TX500_ActiveStationProfile"] mutableCopy] ?: [NSMutableDictionary new];
    NSDictionary *map=@{@"station.qthCity":@"city",@"station.cqZone":@"cqZone",@"station.ituZone":@"ituZone",@"station.iota":@"iota",@"station.operatorName":@"operatorName"};
    [map enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *local,BOOL *stop){ if(values[key]) profile[local]=values[key]; }];
    [NSUserDefaults.standardUserDefaults setObject:profile forKey:@"TX500_ActiveStationProfile"];
    self.status.stringValue=@"Imported station identity. Reopen Station or restart to use it; no contact history or radio settings changed.";
}
- (void)openLogs:(id)sender { NSURL *url=[RadioFamilySupport.rootURL URLByAppendingPathComponent:@"Logs"]; [NSFileManager.defaultManager createDirectoryAtURL:url withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil]; [NSWorkspace.sharedWorkspace openURL:url]; }
- (void)exportLogs:(id)sender {
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"Radio-Utility-Family-Logs.zip";
    if([panel runModal]!=NSModalResponseOK||!panel.URL) return; NSURL *target=panel.URL;
    self.status.stringValue=@"Exporting family logs…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        NSURL *folder=[RadioFamilySupport.rootURL URLByAppendingPathComponent:@"Logs"]; [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
        NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:@"/usr/bin/ditto"]; task.arguments=@[@"-c",@"-k",@"--keepParent",folder.path,target.path]; task.standardOutput=NSFileHandle.fileHandleWithNullDevice; task.standardError=NSFileHandle.fileHandleWithNullDevice;
        NSError *error=nil; BOOL ok=[task launchAndReturnError:&error]; if(ok) { [task waitUntilExit]; ok=task.terminationStatus==0; }
        dispatch_async(dispatch_get_main_queue(),^{ self.status.stringValue=ok?@"Exported family diagnostic logs.":@"Could not export family logs."; });
    });
}

+ (NSDictionary *)credentialQuery:(NSString *)appID {
    if(![@[@"fx-radio-utility",@"icom-radio-utility",@"lab599-utility",@"xiegu-utility"] containsObject:appID]) return nil;
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:@"com.factoreal.radiofamily.log-services",(__bridge id)kSecAttrAccount:[appID stringByAppendingString:@".credentials.v1"],(__bridge id)kSecAttrSynchronizable:@NO};
}
+ (NSDictionary *)secretMapping {
    return @{@"lotw.password":@"TX500_LoTW_Password",@"lotw.certificatePassword":@"TX500_LoTW_CertificatePassword",
             @"qrz.key":@"TX500_QRZ_APIKey",@"qrz.password":@"TX500_QRZ_Password",@"clublog.password":@"TX500_ClubLog_Password",
             @"clublog.apiKey":@"TX500_ClubLog_APIKey",@"eqsl.password":@"TX500_EQSL_Password"};
}
+ (NSDictionary *)accountMapping {
    return @{@"lotw.location":@"TX500_LoTW_StationLocation",@"lotw.username":@"TX500_LoTW_Username",@"qrz.callsign":@"TX500_QRZ_Username",
             @"clublog.callsign":@"TX500_ClubLog_Callsign",@"clublog.email":@"TX500_ClubLog_Email",@"eqsl.callsign":@"TX500_EQSL_Username",@"eqsl.qth":@"TX500_EQSL_Nickname"};
}
- (BOOL)credentialsEnabled { return self.enabled && [NSUserDefaults.standardUserDefaults boolForKey:@"radio.family.credentialSharing.enabled"]; }
- (void)credentialSharingChanged:(id)sender {
    BOOL enabled=self.credentialSharing.state==NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"radio.family.credentialSharing.enabled"];
    if(!enabled) {
        OSStatus result=SecItemDelete((__bridge CFDictionaryRef)[RadioFamilySupport credentialQuery:@"lab599-utility"]);
        self.status.stringValue=(result==errSecSuccess||result==errSecItemNotFound)?@"Credential sharing is off; this app’s shared Keychain record was removed.":@"Credential sharing is off, but macOS could not remove the previously published record. Review it in Keychain Access.";
    }
}
- (void)publishCredentials:(id)sender {
    if(!self.credentialsEnabled) { self.status.stringValue=@"Enable both station and credential sharing first."; return; }
    NSMutableDictionary *values=[NSMutableDictionary new];
    [RadioFamilySupport.secretMapping enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *local,BOOL *stop){ NSString *v=TX500SecretValue(local); if(v.length) values[key]=v; }];
    [RadioFamilySupport.accountMapping enumerateKeysAndObjectsUsingBlock:^(NSString *key,NSString *local,BOOL *stop){ NSString *v=[NSUserDefaults.standardUserDefaults stringForKey:local]; if(v.length) values[key]=v; }];
    NSDictionary *snapshot=@{@"schemaVersion":@1,@"source":RadioFamilySupport.identity,@"updatedAtUTC":RadioFamilySupport.timestamp,@"values":values};
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    NSDictionary *query=[RadioFamilySupport credentialQuery:@"lab599-utility"];
    OSStatus result=SecItemUpdate((__bridge CFDictionaryRef)query,(__bridge CFDictionaryRef)@{(__bridge id)kSecValueData:data});
    if(result==errSecItemNotFound) { NSMutableDictionary *item=[query mutableCopy]; item[(__bridge id)kSecValueData]=data; item[(__bridge id)kSecAttrLabel]=@"Radio Utility Family · Lab599 Utility"; result=SecItemAdd((__bridge CFDictionaryRef)item,NULL); }
    self.status.stringValue=result==errSecSuccess?@"Published supported log-service credentials to macOS Keychain. They are excluded from log exports.":@"macOS did not permit publishing credentials. No values were logged.";
}
- (void)importCredentials:(id)sender {
    NSDictionary *selected=self.selected;
    if(!self.credentialsEnabled||!selected) { self.status.stringValue=@"Enable sharing and select a source app first."; return; }
    NSString *appID=selected[@"source"][@"appID"]; NSDictionary *key=[RadioFamilySupport credentialQuery:appID]; if(!key) return;
    NSMutableDictionary *query=[key mutableCopy]; query[(__bridge id)kSecReturnData]=@YES; query[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
    CFTypeRef result=NULL; OSStatus code=SecItemCopyMatching((__bridge CFDictionaryRef)query,&result);
    if(code!=errSecSuccess) { self.status.stringValue=@"Shared credentials are locked, missing, or not authorized by macOS."; return; }
    NSData *data=CFBridgingRelease(result);
    NSDictionary *snapshot=([data isKindOfClass:NSData.class]&&data.length<=180000)?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    if(![snapshot isKindOfClass:NSDictionary.class]||![snapshot[@"schemaVersion"] isEqual:@1]||![snapshot[@"source"] isKindOfClass:NSDictionary.class]||![snapshot[@"source"][@"appID"] isEqual:appID]||![snapshot[@"values"] isKindOfClass:NSDictionary.class]) { self.status.stringValue=@"Invalid shared credential record."; return; }
    NSMutableDictionary *values=[snapshot[@"values"] mutableCopy];
    for(id value in values.allValues) if(![value isKindOfClass:NSString.class]||[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>8192) { self.status.stringValue=@"Invalid shared credential values."; return; }
    if(!values[@"qrz.key"]&&values[@"qrz.apiKey"]) values[@"qrz.key"]=values[@"qrz.apiKey"];
    __block BOOL ok=YES;
    [RadioFamilySupport.secretMapping enumerateKeysAndObjectsUsingBlock:^(NSString *shared,NSString *local,BOOL *stop){ NSString *v=values[shared]; if(v.length) ok &= TX500StoreSecret(local,v); }];
    [RadioFamilySupport.accountMapping enumerateKeysAndObjectsUsingBlock:^(NSString *shared,NSString *local,BOOL *stop){ NSString *v=values[shared]; if(v) [NSUserDefaults.standardUserDefaults setObject:v forKey:local]; }];
    self.status.stringValue=ok?@"Imported supported log-service credentials. Reopen Cloud Settings to refresh. No upload permission was enabled.":@"Some credentials could not be saved. Review Cloud Settings; no credential values were logged.";
}
@end
