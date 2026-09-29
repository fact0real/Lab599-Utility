#import <Foundation/Foundation.h>
#import "Lab599FirmwareCatalog.h"

@interface Lab599FirmwareCatalog (SecurityTest)
- (NSArray<Lab599FirmwareItem *> *)parseFirmwareItemsFromHTML:(NSString *)html;
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(void) {
    @autoreleasepool {
        Lab599FirmwareCatalog *catalog = [Lab599FirmwareCatalog sharedCatalog];
        NSString *html = @"<a href='https://downloads.lab599.com/TX500/mtrx1.29.06.fw'>TX-500PRO Firmware v9.99.99</a>"
            @"<a href='https://downloads.lab599.com/TX500/mtrx1.30.00.fw'>TX-500 Firmware v1.30.00</a>"
            @"<a href='https://downloads.lab599.com/TX500PRO/mtrx_alt1.29.05.fw'>ALTAI Firmware</a>"
            @"<a href='https://downloads.lab599.com/TX500MP/mtrxMP1.30.00b27.fw'>Patch</a>"
            @"<a href='http://downloads.lab599.com/TX500/mtrx1.30.00.fw'>HTTP downgrade</a>"
            @"<a href='https://downloads.lab599.com.evil.example/TX500/mtrx1.30.00.fw'>Host suffix</a>"
            @"<a href='https://downloads.lab599.com/TX500/new-firmware.fw'>Unreviewed file</a>"
            @"<a href='https://downloads.lab599.com/TX500/mtrx1.30.00.fw?redirect=evil'>Query</a>";
        NSArray<Lab599FirmwareItem *> *items = [catalog parseFirmwareItemsFromHTML:html];
        Check(items.count == 4, @"Only reviewed HTTPS releases are listed");
        Check([items[0].model isEqualToString:@"TX-500 Discovery"], @"HTML cannot relabel the radio model");
        Check([items[0].version isEqualToString:@"1.29.06"], @"HTML cannot spoof version");
        Check(!items[0].isLatest && items[1].isLatest, @"Latest is determined by version, not page order");
        Check([items[2].model isEqualToString:@"TX-500PRO ALTAI"], @"ALTAI target comes from reviewed path");
        Check(!items[3].isLatest, @"Patch is not marked latest");
        for (Lab599FirmwareItem *item in items)
            Check(item.expectedSHA256.length == 64, @"Every listed release has a SHA-256 pin");

        Lab599FirmwareItem *unknown = [Lab599FirmwareItem new];
        unknown.downloadURL = [NSURL URLWithString:@"https://downloads.lab599.com/TX500/new-firmware.fw"];
        unknown.expectedSHA256 = @"fake";
        __block BOOL rejected = NO;
        NSURLSessionDownloadTask *task = [catalog downloadFirmware:unknown progress:nil completion:^(NSURL *url, NSString *hash, NSError *error) {
            (void)url; (void)hash;
            rejected = error != nil;
        }];
        Check(task == nil, @"Unknown release cannot start a network download");
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
        while (!rejected && [deadline timeIntervalSinceNow] > 0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        Check(rejected, @"Unknown release reports a rejection");
        puts("PASS: firmware catalog allows only reviewed releases and rejects forged metadata");
    }
    return 0;
}
