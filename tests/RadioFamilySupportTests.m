#import "RadioFamilySupport.h"
@interface RadioFamilySupport (TestingContract)
+ (BOOL)validValues:(NSDictionary *)values;
@end
int main(void) { @autoreleasepool {
    NSCAssert(getenv("RADIO_FAMILY_TEST_ROOT"),@"A disposable test root is required");
    NSURL *root=RadioFamilySupport.rootURL;
    [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *old=[root URLByAppendingPathComponent:@"old.log"]; NSData *sentinel=[@"old evidence\n" dataUsingEncoding:NSUTF8StringEncoding]; [sentinel writeToURL:old atomically:YES];
    dispatch_apply(400,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t i){
        [RadioFamilySupport recordEvent:@"sample" details:@{@"sequence":@(i),@"appName":@"forged"}];
    });
    [RadioFamilySupport flushDiagnostics];
    NSDirectoryEnumerator *enumerator=[NSFileManager.defaultManager enumeratorAtURL:[root URLByAppendingPathComponent:@"Logs"] includingPropertiesForKeys:nil options:0 errorHandler:nil];
    NSUInteger rows=0; NSMutableSet *sequences=[NSMutableSet new];
    for(NSURL *url in enumerator) if([url.pathExtension isEqual:@"jsonl"]) {
        NSString *content=[NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        for(NSString *line in [content componentsSeparatedByString:@"\n"]) if(line.length) {
            NSDictionary *r=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            NSCAssert([r[@"appID"] isEqual:@"lab599-utility"],@"Stable product identity required");
            NSCAssert([r[@"appName"] isEqual:@"Lab599 Utility"],@"Original product name overrides injected fields");
            NSCAssert([r[@"schemaVersion"] isEqual:@1] && [r[@"appVersion"] length] && [r[@"appBuild"] length] && [r[@"runID"] length],@"Provenance contract");
            [sequences addObject:r[@"sequence"]]; rows++;
        }
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:url.path error:nil];
        NSCAssert([attributes[NSFilePosixPermissions] unsignedShortValue]==0600,@"Private diagnostics permissions");
    }
    NSCAssert(rows==400 && sequences.count==400,@"Concurrent logging must preserve every event");
    NSCAssert([[NSData dataWithContentsOfURL:old] isEqual:sentinel],@"Existing logs must remain untouched");
    NSCAssert(([RadioFamilySupport validValues:@{@"station.callsign":@"EP2AES",@"station.grid":@"LM55",@"station.operatorName":@"اپراتور"}]),@"Portable Unicode station identity");
    NSCAssert(![RadioFamilySupport validValues:@{@"password":@"not-shared"}],@"Secrets do not belong in settings JSON");
    NSCAssert(![RadioFamilySupport validValues:@{@"station.grid":@"ZZ99"}],@"Invalid locator rejected");
    NSCAssert(![RadioFamilySupport validValues:@{@"station.cqZone":@"41"}],@"Invalid CQ zone rejected");
    puts("Radio family contract: 400 records, provenance, settings boundaries and old-log preservation passed.");
} return 0; }
