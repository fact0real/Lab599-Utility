// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500SSTVLogDraft.h"

@implementation TX500SSTVLogDraft {
    NSString *_submode;
}

- (instancetype)initWithPicture:(TX500SSTVPicture *)picture catFrequencyHz:(nullable NSNumber *)catFrequencyHz {
    if ((self = [super init])) {
        _picture = picture;
        _endUTC = [picture.endUTC copy];
        _fromFile = picture.fromFile;
        _submode = [picture.modeName copy];
        _callsign = @"";
        _rsv = @"";
        uint64_t hz = picture.fromFile ? 0 : catFrequencyHz.unsignedLongLongValue;
        _frequencyHz = hz;
        _frequencyFromCAT = hz > 0;
        _upload = NO;
    }
    return self;
}

- (instancetype)initWithReception:(TX500SSTVStoredReception *)reception picture:(nullable TX500SSTVPicture *)picture {
    if ((self = [super init])) {
        _picture = picture;
        _reception = reception;
        _endUTC = [reception.endUTC copy];
        _fromFile = reception.fromFile;
        _submode = [(picture.modeName.length ? picture.modeName : reception.modeName) copy] ?: @"";
        _callsign = @"";
        _rsv = @"";
        _frequencyHz = reception.fromFile ? 0 : reception.catFrequencyHz;
        _frequencyFromCAT = _frequencyHz > 0;
        _upload = NO;
    }
    return self;
}

- (NSString *)mode { return @"SSTV"; }
- (NSString *)submode { return _submode ?: @""; }

- (NSString *)band {
    if (!self.frequencyHz) return @"";
    NSString *b = [TX500LogRecord bandForFrequencyHz:self.frequencyHz];
    return [b isEqualToString:@"HF"] ? @"" : b;      // "HF" is the band plan's "none of mine": not a band
}

static BOOL SSTVValidCallsign(NSString *c) {
    if (c.length < 3 || c.length > 15) return NO;
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/"];
    if ([c rangeOfCharacterFromSet:ok.invertedSet].location != NSNotFound) return NO;
    return [c rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location != NSNotFound;
}

- (nullable NSString *)problem {
    if (self.fromFile) return @"Pictures decoded from a file are practice: they are never logged.";
    if (self.reception.logged) return @"This reception is already in the logbook: a reception is logged once.";
    NSString *call = [[self.callsign stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
    if (!call.length) return @"Enter the callsign you see in the picture.";
    if (!SSTVValidCallsign(call)) return @"That does not look like a callsign.";
    if (self.frequencyInvalid) return @"The frequency is in MHz, from 0.5 to 56 (for example 14.230).";
    if (!self.frequencyHz) return @"Enter the frequency before logging (the radio gave no valid reading).";
    return nil;
}

- (nullable TX500LogRecord *)record {
    if ([self problem]) return nil;
    TX500LogRecord *r = [[TX500LogRecord alloc] init];
    r.callsign = [[self.callsign stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
    r.frequencyHz = self.frequencyHz;
    r.band = self.band;
    r.mode = self.mode;
    // ADIF 3.1.7 lists no submode for SSTV, and SUBMODE takes the listed values (for interoperability):
    // the picture's mode goes to COMMENT instead (SEG-23)
    r.submode = nil;
    r.notes = self.submode.length ? self.submode : nil;
    // every default of a new record is replaced: nothing here was measured or said
    r.rstSent = @"";
    r.rstRcvd = [self.rsv stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    r.powerWatts = 0;
    r.myCall = self.myCallsign.length ? self.myCallsign.uppercaseString : nil;
    // only what is needed of the station (SEG-19): no copy of the profile (devices, name, rig…)
    r.stationProfile = nil;
    NSString *grid = [[self.myGrid stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] uppercaseString];
    r.myGrid = [grid rangeOfString:@"^[A-R]{2}[0-9]{2}([A-X]{2}([0-9]{2})?)?$" options:NSRegularExpressionSearch].location != NSNotFound ? grid : nil;
    NSDateFormatter *d = [NSDateFormatter new], *t = [NSDateFormatter new];
    d.timeZone = t.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    d.locale = t.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    d.dateFormat = @"yyyyMMdd";
    t.dateFormat = @"HHmmss";
    r.qsoDate = [d stringFromDate:self.endUTC];
    r.timeOn = [t stringFromDate:self.endUTC];
    r.timeOff = r.timeOn;
    return r;
}

@end
