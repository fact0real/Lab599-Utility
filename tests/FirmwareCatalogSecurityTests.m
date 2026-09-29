#import <Foundation/Foundation.h>
#import "Lab599FirmwareCatalog.h"
#include <stdint.h>
#include <string.h>

@interface Lab599FirmwareCatalog (SecurityTest)
- (NSArray<Lab599FirmwareItem *> *)parseFirmwareItemsFromHTML:(NSString *)html;
@end

static void Check(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

int main(int argc, const char *argv[]) {
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

        Check(argc == 2 || argc == 5, @"Supply Discovery firmware and optionally MP, PRO and ALTAI fixtures");
        NSData *discovery = [NSData dataWithContentsOfFile:@(argv[1])];
        Check(discovery.length > 16, @"Reviewed Discovery fixture is available");
        Check([[Lab599FirmwareCatalog reviewedModelForFirmwareData:discovery] isEqualToString:@"TX-500 Discovery"],
              @"Complete reviewed firmware identifies its target independently of filename");
        Check([Lab599FirmwareCatalog preflightErrorForFirmwareData:discovery declaredRadioModel:@"TX-500 Discovery"] == nil,
              @"Matching declared radio model passes preflight");
        Check([Lab599FirmwareCatalog preflightErrorForFirmwareData:discovery declaredRadioModel:@"TX-500MP"] != nil,
              @"Cross-model firmware is hard blocked");
        Check([Lab599FirmwareCatalog preflightErrorForFirmwareData:discovery declaredRadioModel:nil] != nil,
              @"No radio model selection is hard blocked");
        Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500 Discovery" reply:@"ID500;"] == nil,
              @"Normal-mode TX-500 CAT identity permits Discovery family firmware");
        Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500 Discovery" reply:@"ID505;"] != nil,
              @"MP radio blocks Discovery firmware before loader entry");
        Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500MP" reply:@"ID505;"] == nil,
              @"Normal-mode MP CAT identity permits MP firmware");
        Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500MP" reply:@"ID500;"] != nil,
              @"TX-500 radio blocks MP firmware before loader entry");
        Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500PRO" reply:@"ID500;"] == nil &&
              [Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500PRO ALTAI" reply:@"ID500;"] == nil,
              @"PRO and ALTAI use only the documented TX-500 family check");
        for (NSString *reply in @[@"ID019;", @"ID501;", @"ID502;", @"ID500;extra", @"id500;", @"", @"ID;", @"ID505;\n"])
            Check([Lab599FirmwareCatalog CATIdentityErrorForFirmwareModel:@"TX-500 Discovery" reply:reply] != nil,
                  @"Generic, undocumented, or malformed CAT reply fails closed");
        NSMutableData *tampered = [discovery mutableCopy];
        ((uint8_t *)tampered.mutableBytes)[32] ^= 1;
        Check([Lab599FirmwareCatalog reviewedModelForFirmwareData:tampered] == nil,
              @"Changed payload is rejected even with a valid BL20 header");
        NSMutableData *wrongHeader = [discovery mutableCopy];
        memcpy((uint8_t *)wrongHeader.mutableBytes + 12, "\x96\x3b\xcd\xf4", 4);
        Check([Lab599FirmwareCatalog reviewedModelForFirmwareData:wrongHeader] == nil,
              @"Changed BL20 model ID is rejected even when the filename is trusted");
        Check([Lab599FirmwareCatalog reviewedModelForFirmwareData:[discovery subdataWithRange:NSMakeRange(0, 16)]] == nil,
              @"Header-only firmware is rejected");
        if (argc == 5) {
            NSArray<NSString *> *models = @[@"TX-500MP", @"TX-500PRO", @"TX-500PRO ALTAI"];
            for (NSUInteger index = 0; index < models.count; index++) {
                NSData *fixture = [NSData dataWithContentsOfFile:@(argv[index + 2])];
                Check([[Lab599FirmwareCatalog reviewedModelForFirmwareData:fixture] isEqualToString:models[index]],
                      [NSString stringWithFormat:@"Reviewed %@ firmware identifies its target", models[index]]);
                Check([Lab599FirmwareCatalog preflightErrorForFirmwareData:fixture declaredRadioModel:models[index]] == nil,
                      [NSString stringWithFormat:@"Reviewed %@ firmware passes a matching declaration", models[index]]);
                Check([Lab599FirmwareCatalog preflightErrorForFirmwareData:fixture declaredRadioModel:@"TX-500 Discovery"] != nil,
                      [NSString stringWithFormat:@"%@ firmware cannot be flashed with a Discovery declaration", models[index]]);
            }
        }
        puts("PASS: firmware catalog allows only reviewed releases and rejects forged metadata");
    }
    return 0;
}
