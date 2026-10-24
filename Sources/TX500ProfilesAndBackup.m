#import "TX500ProfilesAndBackup.h"

// =============================================================================
// Helper string utilities
// =============================================================================

static NSString *ModeName(uint8_t code) {
    switch (code) {
        case '1': return @"LSB";
        case '2': return @"USB";
        case '3': return @"CW";
        case '4': return @"FM";
        case '5': return @"AM";
        case '6': return @"DIG";
        case '7': return @"CWR";
        default:  return @"USB";
    }
}

static uint8_t ParseModeString(NSString *str) {
    NSString *clean = [[str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean isEqualToString:@"LSB"] || [clean isEqualToString:@"1"]) return '1';
    if ([clean isEqualToString:@"USB"] || [clean isEqualToString:@"2"]) return '2';
    if ([clean isEqualToString:@"DIG"] || [clean isEqualToString:@"DIGITAL"] || [clean isEqualToString:@"6"]) return '6';
    if ([clean isEqualToString:@"CW"]  || [clean isEqualToString:@"3"]) return '3';
    if ([clean isEqualToString:@"FM"]  || [clean isEqualToString:@"4"]) return '4';
    if ([clean isEqualToString:@"AM"]  || [clean isEqualToString:@"5"]) return '5';
    if ([clean isEqualToString:@"CWR"] || [clean isEqualToString:@"7"]) return '7';
    return 0;
}

static NSString *PreAttName(uint8_t code) {
    switch (code) {
        case '1': return @"PRE";
        case '2': return @"ATT";
        default:  return @"Off";
    }
}

static uint8_t ParsePreAttString(NSString *str) {
    NSString *clean = [[str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean isEqualToString:@"PRE"] || [clean isEqualToString:@"PREAMP"] || [clean isEqualToString:@"1"]) return '1';
    if ([clean isEqualToString:@"ATT"] || [clean isEqualToString:@"ATTENUATOR"] || [clean isEqualToString:@"2"]) return '2';
    return '0';
}

// =============================================================================
// CSV Import & Export Implementation
// =============================================================================

NSString *TXExportMemoryToCSV(NSArray<TXMemoryChannel *> *channels) {
    NSMutableString *csv = [NSMutableString string];
    [csv appendString:@"Channel,Frequency_Hz,Frequency_MHz,Mode,PreAtt,Status\n"];

    for (NSUInteger i = 0; i < channels.count && i < 100; i++) {
        TXMemoryChannel *ch = channels[i];
        if (ch.frequency > 0) {
            double mhz = (double)ch.frequency / 1000000.0;
            [csv appendFormat:@"%02lu,%u,%.6f,%@,%@,Active\n",
                (unsigned long)i,
                ch.frequency,
                mhz,
                ModeName(ch.mode),
                PreAttName(ch.preAtt)];
        } else {
            [csv appendFormat:@"%02lu,0,0.000000,%@,%@,Empty\n",
                (unsigned long)i,
                ModeName(ch.mode),
                PreAttName(ch.preAtt)];
        }
    }
    return [csv copy];
}

NSArray<TXMemoryChannel *> *TXImportMemoryFromCSV(NSString *csvString, NSError **error) {
    return TXImportMemoryFromCSVWithReport(csvString, NULL, error);
}

NSArray<TXMemoryChannel *> *TXImportMemoryFromCSVWithReport(NSString *csvString, NSDictionary **report, NSError **error) {
    if (error) *error=nil;
    NSMutableArray<TXMemoryChannel *> *bank=[TXEmptyMemory() mutableCopy];
    NSArray *lines=[[csvString ?: @"" stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray *reasons=[NSMutableArray array];
    NSMutableSet *used=[NSMutableSet set];
    __block NSUInteger skipped=0;
    NSUInteger imported=0, next=0, lineNumber=0;
    for(NSString *raw in lines) {
        lineNumber++;
        NSString *line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(!line.length || [line hasPrefix:@"#"]) continue;
        void (^skip)(NSString *)=^(NSString *why) {
            skipped++;
            if(reasons.count<8) [reasons addObject:[NSString stringWithFormat:@"Line %lu: %@",(unsigned long)lineNumber,why]];
        };
        NSString *separator=[line containsString:@","] ? @"," : [line containsString:@";"] ? @";" : [line containsString:@"\t"] ? @"\t" : nil;
        if(!separator || [line containsString:@"\""]) { skip(@"Missing separator or unsupported quoted field"); continue; }
        NSMutableArray *parts=[NSMutableArray array];
        for(NSString *part in [line componentsSeparatedByString:separator]) [parts addObject:[part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        NSString *first=[parts[0] uppercaseString];
        if([@[@"CHANNEL",@"CH",@"FREQ",@"FREQUENCY"] containsObject:first]) continue;
        if(parts.count<2) { skip(@"At least two columns are required"); continue; }
        NSInteger possible=0;
        NSScanner *scanner=[NSScanner scannerWithString:parts[0]];
        BOOL integer=[scanner scanInteger:&possible] && scanner.isAtEnd;
        BOOL hasChannel=integer && possible<100000;
        NSInteger channel=hasChannel ? possible : (NSInteger)next;
        if(channel<0 || channel>=100) { skip(@"Channel must be between 0 and 99"); continue; }
        if([used containsObject:@(channel)]) { skip(@"Duplicate channel; earlier row kept"); continue; }
        NSString *freq=parts[hasChannel ? 1 : 0];
        NSString *mode=@"USB", *pre=@"Off";
        if(hasChannel) {
            NSUInteger modeColumn=(parts.count>=4 && [parts[2] containsString:@"."]) ? 3 : 2;
            if(parts.count>modeColumn) mode=parts[modeColumn];
            if(parts.count>modeColumn+1) pre=parts[modeColumn+1];
        } else { mode=parts[1]; if(parts.count>2) pre=parts[2]; }
        double number=0;
        scanner=[NSScanner scannerWithString:freq]; scanner.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        if(![scanner scanDouble:&number] || !scanner.isAtEnd || !isfinite(number)) { skip(@"Frequency is not a finite number"); continue; }
        double hz=[freq containsString:@"."] ? number*1000000.0 : number;
        if(hz<0 || (hz>0 && (hz<100000 || hz>56000000))) { skip(@"Frequency outside 100 kHz–56 MHz"); continue; }
        uint8_t modeCode=ParseModeString(mode);
        if(!modeCode) { skip(@"Unsupported mode; no USB substitution made"); continue; }
        NSString *preUpper=pre.uppercaseString;
        if(![@[@"OFF",@"0",@"PRE",@"PREAMP",@"1",@"ATT",@"ATTENUATOR",@"2"] containsObject:preUpper]) { skip(@"Unsupported preamp/attenuator value"); continue; }
        [used addObject:@(channel)];
        if(hz>0) {
            TXMemoryChannel *entry=[TXMemoryChannel new];
            entry.frequency=(uint32_t)llround(hz); entry.mode=modeCode; entry.preAtt=ParsePreAttString(pre);
            bank[(NSUInteger)channel]=entry; imported++;
        }
        next=(NSUInteger)channel+1;
    }
    if(report) *report=@{@"imported":@(imported),@"skipped":@(skipped),@"reasons":reasons};
    if(!imported) {
        if(error) *error=[NSError errorWithDomain:@"TX500CSV" code:2 userInfo:@{NSLocalizedDescriptionKey:@"No valid active frequency records found in CSV file."}];
        return nil;
    }
    return bank;
}

// =============================================================================
// Operating Profiles Implementation
// =============================================================================

@implementation TXOperatingProfile
@end

@implementation TXProfileManager

+ (NSArray<TXOperatingProfile *> *)builtInProfiles {
    NSMutableArray<TXOperatingProfile *> *profiles = [NSMutableArray array];

    // 1. SOTA / POTA Portable QRP Profile
    {
        TXOperatingProfile *p = [TXOperatingProfile new];
        p.name = @"SOTA / POTA (QRP Portable)";
        p.details = @"Standard QRP calling channels for Summits & Parks on the Air.";
        p.isBuiltIn = YES;
        NSMutableArray<TXMemoryChannel *> *channels = [TXEmptyMemory() mutableCopy];

        struct { uint32_t freq; uint8_t mode; uint8_t pre; } sotaFreqs[] = {
            { 7030000,  '3', '0' }, // 40m CW
            { 7090000,  '1', '0' }, // 40m SSB
            { 7110000,  '1', '0' }, // 40m SSB Calling
            { 10116000, '3', '0' }, // 30m CW
            { 14060000, '3', '0' }, // 20m CW
            { 14285000, '2', '0' }, // 20m SSB
            { 14342000, '2', '0' }, // 20m SSB Calling
            { 18086000, '3', '0' }, // 17m CW
            { 18130000, '2', '0' }, // 17m SSB
            { 21060000, '3', '0' }, // 15m CW
            { 21285000, '2', '0' }, // 15m SSB
            { 24906000, '3', '0' }, // 12m CW
            { 28060000, '3', '0' }, // 10m CW
            { 28360000, '2', '0' }  // 10m SSB
        };
        for (NSUInteger i = 0; i < sizeof(sotaFreqs)/sizeof(sotaFreqs[0]); i++) {
            TXMemoryChannel *ch = [TXMemoryChannel new];
            ch.frequency = sotaFreqs[i].freq;
            ch.mode = sotaFreqs[i].mode;
            ch.preAtt = sotaFreqs[i].pre;
            channels[i] = ch;
        }
        p.channels = channels;
        [profiles addObject:p];
    }

    // 2. Digital FT8 & JS8Call Profile
    {
        TXOperatingProfile *p = [TXOperatingProfile new];
        p.name = @"Digital FT8 / JS8Call";
        p.details = @"Standard international FT8 digital calling frequencies (160m to 6m).";
        p.isBuiltIn = YES;
        NSMutableArray<TXMemoryChannel *> *channels = [TXEmptyMemory() mutableCopy];

        uint32_t ft8Freqs[] = {
            1840000,   // 160m FT8
            3573000,   // 80m FT8
            5357000,   // 60m FT8
            7074000,   // 40m FT8
            10136000,  // 30m FT8
            14074000,  // 20m FT8
            18100000,  // 17m FT8
            21074000,  // 15m FT8
            24915000,  // 12m FT8
            28074000,  // 10m FT8
            50313000,  // 6m FT8
            7078000,   // 40m JS8
            14078000,  // 20m JS8
            28078000   // 10m JS8
        };
        for (NSUInteger i = 0; i < sizeof(ft8Freqs)/sizeof(ft8Freqs[0]); i++) {
            TXMemoryChannel *ch = [TXMemoryChannel new];
            ch.frequency = ft8Freqs[i];
            ch.mode = '2'; // USB
            ch.preAtt = '0'; // Off
            channels[i] = ch;
        }
        p.channels = channels;
        [profiles addObject:p];
    }

    // 3. CW Contest & DX Calling Profile
    {
        TXOperatingProfile *p = [TXOperatingProfile new];
        p.name = @"CW Contest & DX Calling";
        p.details = @"Centers of activity for international telegraphy (CW).";
        p.isBuiltIn = YES;
        NSMutableArray<TXMemoryChannel *> *channels = [TXEmptyMemory() mutableCopy];

        uint32_t cwFreqs[] = {
            1820000,   // 160m CW DX
            3520000,   // 80m CW DX
            7020000,   // 40m CW DX
            10110000,  // 30m CW
            14020000,  // 20m CW DX
            18070000,  // 17m CW
            21020000,  // 15m CW DX
            24895000,  // 12m CW
            28020000,  // 10m CW DX
            50090000   // 6m CW DX
        };
        for (NSUInteger i = 0; i < sizeof(cwFreqs)/sizeof(cwFreqs[0]); i++) {
            TXMemoryChannel *ch = [TXMemoryChannel new];
            ch.frequency = cwFreqs[i];
            ch.mode = '3'; // CW
            ch.preAtt = '0';
            channels[i] = ch;
        }
        p.channels = channels;
        [profiles addObject:p];
    }

    // 4. SSB Voice & Activity Nets
    {
        TXOperatingProfile *p = [TXOperatingProfile new];
        p.name = @"SSB Voice & Activity Nets";
        p.details = @"Popular HF voice calling and emergency nets.";
        p.isBuiltIn = YES;
        NSMutableArray<TXMemoryChannel *> *channels = [TXEmptyMemory() mutableCopy];

        struct { uint32_t freq; uint8_t mode; } ssbFreqs[] = {
            { 3750000,  '1' }, // 80m LSB
            { 7150000,  '1' }, // 40m LSB
            { 7200000,  '1' }, // 40m LSB Net
            { 14200000, '2' }, // 20m USB
            { 14250000, '2' }, // 20m USB Net
            { 14300000, '2' }, // 20m Maritime Mobile Net
            { 18150000, '2' }, // 17m USB
            { 21300000, '2' }, // 15m USB
            { 28400000, '2' }, // 10m USB
            { 50125000, '2' }  // 6m USB Calling
        };
        for (NSUInteger i = 0; i < sizeof(ssbFreqs)/sizeof(ssbFreqs[0]); i++) {
            TXMemoryChannel *ch = [TXMemoryChannel new];
            ch.frequency = ssbFreqs[i].freq;
            ch.mode = ssbFreqs[i].mode;
            ch.preAtt = '0';
            channels[i] = ch;
        }
        p.channels = channels;
        [profiles addObject:p];
    }

    // 5. 60m Channels & Maritime Emergency
    {
        TXOperatingProfile *p = [TXOperatingProfile new];
        p.name = @"60m Channels & Emergency";
        p.details = @"WRC-15 and standard 60m channelized USB frequencies.";
        p.isBuiltIn = YES;
        NSMutableArray<TXMemoryChannel *> *channels = [TXEmptyMemory() mutableCopy];

        uint32_t emFreqs[] = {
            5330500,  // Ch 1
            5346500,  // Ch 2
            5357000,  // Ch 3
            5371500,  // Ch 4
            5403500,  // Ch 5
            14300000, // Maritime Net
            2182000   // International Distress
        };
        for (NSUInteger i = 0; i < sizeof(emFreqs)/sizeof(emFreqs[0]); i++) {
            TXMemoryChannel *ch = [TXMemoryChannel new];
            ch.frequency = emFreqs[i];
            ch.mode = '2'; // USB
            ch.preAtt = '0';
            channels[i] = ch;
        }
        p.channels = channels;
        [profiles addObject:p];
    }

    return [profiles copy];
}

+ (NSString *)profilesDirectoryPath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [appSupport stringByAppendingPathComponent:@"Lab599 Utility/Profiles"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return dir;
}

+ (NSArray<TXOperatingProfile *> *)userProfiles {
    NSString *dir = [self profilesDirectoryPath];
    NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    NSMutableArray<TXOperatingProfile *> *profiles = [NSMutableArray array];

    for (NSString *file in files) {
        if (![file hasSuffix:@".mem"] && ![file hasSuffix:@".set"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:file];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;

        if ([file hasSuffix:@".mem"] && data.length == 600) {
            NSError *err = nil;
            NSArray<TXMemoryChannel *> *channels = TXDecodeMemory(data, &err);
            if (channels) {
                TXOperatingProfile *p = [TXOperatingProfile new];
                p.name = [file stringByDeletingPathExtension];
                p.details = @"Custom User Memory Profile";
                p.isBuiltIn = NO;
                p.channels = channels;
                [profiles addObject:p];
            }
        }
    }
    return [profiles copy];
}

+ (BOOL)saveUserProfileNamed:(NSString *)name channels:(NSArray<TXMemoryChannel *> *)channels error:(NSError **)error {
    if (!name.length) {
        if (error) *error = [NSError errorWithDomain:@"TX500Profile" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Profile name cannot be empty."}];
        return NO;
    }
    NSString *dir = [self profilesDirectoryPath];
    NSString *safeName = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *path = [[dir stringByAppendingPathComponent:safeName] stringByAppendingPathExtension:@"mem"];

    NSData *data = TXEncodeMemory(channels, error);
    if (!data) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:error];
}

+ (BOOL)deleteUserProfileNamed:(NSString *)name error:(NSError **)error {
    NSString *dir = [self profilesDirectoryPath];
    NSString *safeName = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    NSString *path = [[dir stringByAppendingPathComponent:safeName] stringByAppendingPathExtension:@"mem"];
    return [[NSFileManager defaultManager] removeItemAtPath:path error:error];
}

@end

// =============================================================================
// Backup Comparison Engine Implementation
// =============================================================================

@implementation TXSettingsDiffItem
@end

@implementation TXSettingsComparisonResult
@end

#import "TX500SettingsModel.h"

TXSettingsComparisonResult *TXCompareSettings(NSData *dataA, NSData *dataB, NSString *nameA, NSString *nameB) {
    TXSettingsComparisonResult *result = [TXSettingsComparisonResult new];
    result.totalSettings = 1024;

    if (!dataA || !dataB || dataA.length != 1024 || dataB.length != 1024) {
        result.summary = @"Cannot compare: Both files must be exactly 1024 bytes.";
        result.diffItems = @[];
        return result;
    }

    const uint8_t *bytesA = (const uint8_t *)dataA.bytes;
    const uint8_t *bytesB = (const uint8_t *)dataB.bytes;
    NSMutableArray<TXSettingsDiffItem *> *diffs = [NSMutableArray array];

    for (NSUInteger i = 0; i < 1024; i++) {
        if (bytesA[i] != bytesB[i]) {
            TXSettingsDiffItem *item = [TXSettingsDiffItem new];
            item.address = 1000 + i;
            item.valueA = bytesA[i];
            item.valueB = bytesB[i];
            item.settingName = [TX500SettingsModel descriptionForAddress:item.address];
            item.category = [TX500SettingsModel categoryForAddress:item.address];
            item.changeDescription = [NSString stringWithFormat:@"%u  ->  %u  (Δ %+d)",
                bytesA[i], bytesB[i], (int)bytesB[i] - (int)bytesA[i]];
            [diffs addObject:item];
        }
    }

    result.differencesCount = diffs.count;
    result.diffItems = [diffs copy];
    result.summary = [NSString stringWithFormat:@"Comparing '%@' vs '%@': %lu settings differ out of 1024.",
        nameA ?: @"Backup A", nameB ?: @"Backup B", (unsigned long)diffs.count];
    return result;
}

@implementation TXMemoryDiffItem
@end

@implementation TXMemoryComparisonResult
@end

TXMemoryComparisonResult *TXCompareMemory(NSArray<TXMemoryChannel *> *bankA, NSArray<TXMemoryChannel *> *bankB, NSString *nameA, NSString *nameB) {
    TXMemoryComparisonResult *result = [TXMemoryComparisonResult new];
    result.totalChannels = 100;

    NSMutableArray<TXMemoryDiffItem *> *diffs = [NSMutableArray array];
    NSUInteger modified = 0;
    NSUInteger added = 0;
    NSUInteger cleared = 0;
    NSUInteger identical = 0;

    for (NSUInteger i = 0; i < 100; i++) {
        TXMemoryChannel *chA = (i < bankA.count) ? bankA[i] : [TXMemoryChannel new];
        TXMemoryChannel *chB = (i < bankB.count) ? bankB[i] : [TXMemoryChannel new];

        BOOL emptyA = (chA.frequency == 0);
        BOOL emptyB = (chB.frequency == 0);

        TXMemoryDiffItem *item = [TXMemoryDiffItem new];
        item.channelIndex = i;
        item.channelA = chA;
        item.channelB = chB;

        if (emptyA && emptyB) {
            item.status = TXChannelDiffIdentical;
            item.statusText = @"Identical (Empty)";
            identical++;
        } else if (emptyA && !emptyB) {
            item.status = TXChannelDiffAdded;
            item.statusText = @"Added in B";
            added++;
            [diffs addObject:item];
        } else if (!emptyA && emptyB) {
            item.status = TXChannelDiffCleared;
            item.statusText = @"Cleared in B";
            cleared++;
            [diffs addObject:item];
        } else {
            if (chA.frequency == chB.frequency && chA.mode == chB.mode && chA.preAtt == chB.preAtt) {
                item.status = TXChannelDiffIdentical;
                item.statusText = @"Identical";
                identical++;
            } else {
                item.status = TXChannelDiffModified;
                item.statusText = @"Modified";
                modified++;
                [diffs addObject:item];
            }
        }
    }

    result.differencesCount = diffs.count;
    result.identicalCount = identical;
    result.diffItems = [diffs copy];
    result.summary = [NSString stringWithFormat:@"Comparing '%@' vs '%@': %lu differences (%lu modified, %lu added, %lu cleared, %lu identical).",
        nameA ?: @"Bank A", nameB ?: @"Bank B",
        (unsigned long)diffs.count, (unsigned long)modified, (unsigned long)added, (unsigned long)cleared, (unsigned long)identical];
    return result;
}
