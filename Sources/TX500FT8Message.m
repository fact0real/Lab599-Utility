//
//  TX500FT8Message.m
//  Lab599 Utility
//
//  FT8 Message Parser, Maidenhead Grid Geolocation, DXCC Prefix Resolver & ADIF Generator
//

#import "TX500FT8Message.h"
#import <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static double Deg2Rad(double deg) {
    return deg * (M_PI / 180.0);
}

static double Rad2Deg(double rad) {
    return rad * (180.0 / M_PI);
}

@implementation TX500FT8Message

- (instancetype)init {
    self = [super init];
    if (self) {
        _timestamp = [NSDate date];
        _slotParity = 0;
        _countryName = @"Unknown";
        _countryFlag = @"🌐";
        _distanceKm = -1.0;
        _bearingDeg = -1.0;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    TX500FT8Message *copy = [[[self class] allocWithZone:zone] init];
    copy.rawText = self.rawText;
    copy.freqHz = self.freqHz;
    copy.snrDb = self.snrDb;
    copy.timeSec = self.timeSec;
    copy.timingUncertaintySec = self.timingUncertaintySec;
    copy.timingSourceIdentifier = self.timingSourceIdentifier;
    copy.timestamp = self.timestamp;
    copy.slotParity = self.slotParity;
    copy.messageType = self.messageType;
    copy.callerCall = self.callerCall;
    copy.targetCall = self.targetCall;
    copy.grid = self.grid;
    copy.snrReport = self.snrReport;
    copy.isRoger = self.isRoger;
    copy.isCQ = self.isCQ;
    copy.isDirectedToMe = self.isDirectedToMe;
    copy.isMyTransmission = self.isMyTransmission;
    copy.isNewDXCC = self.isNewDXCC;
    copy.isNewGrid = self.isNewGrid;
    copy.isWorkedBefore = self.isWorkedBefore;
    copy.isAlertMatch = self.isAlertMatch;
    copy.countryName = self.countryName;
    copy.countryFlag = self.countryFlag;
    copy.continent = self.continent;
    copy.distanceKm = self.distanceKm;
    copy.bearingDeg = self.bearingDeg;
    return copy;
}

+ (instancetype)messageWithRawText:(NSString *)rawText
                            freqHz:(float)freq
                             snrDb:(float)snr
                                dt:(float)dt
                          slotDate:(nullable NSDate *)slotDate
                        slotParity:(NSInteger)parity
                            myCall:(NSString *)myCall
                            myGrid:(NSString *)myGrid {
    TX500FT8Message *msg = [[TX500FT8Message alloc] init];
    msg.mode = @"FT8";
    msg.rawText = [rawText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    msg.freqHz = freq;
    msg.snrDb = snr;
    msg.timeSec = dt;
    msg.slotParity = parity;

    if (slotDate) {
        msg.timestamp = slotDate;
    } else {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval slotStartEpoch = floor(now / 15.0) * 15.0;
        msg.timestamp = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];
    }

    NSString *cleanMyCall = [[myCall stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    NSString *cleanMyGrid = [[myGrid stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];

    [msg parseContentWithMyCall:cleanMyCall myGrid:cleanMyGrid];
    return msg;
}

+ (instancetype)messageWithRawText:(NSString *)rawText
                            freqHz:(float)freq
                             snrDb:(float)snr
                                dt:(float)dt
                            myCall:(NSString *)myCall
                            myGrid:(NSString *)myGrid {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval slotStartEpoch = floor(now / 15.0) * 15.0;
    NSInteger parity = ((NSInteger)(slotStartEpoch / 15.0)) % 2;
    NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];
    return [self messageWithRawText:rawText
                             freqHz:freq
                              snrDb:snr
                                 dt:dt
                           slotDate:slotDate
                         slotParity:parity
                             myCall:myCall
                             myGrid:myGrid];
}

- (void)parseContentWithMyCall:(NSString *)myCall myGrid:(NSString *)myGrid {
    NSArray<NSString *> *tokens = [self.rawText componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray<NSString *> *nonEmpty = [NSMutableArray array];
    for (NSString *t in tokens) {
        if (t.length > 0) [nonEmpty addObject:[t uppercaseString]];
    }

    if (nonEmpty.count == 0) return;

    // Check if starts with CQ
    if ([nonEmpty[0] isEqualToString:@"CQ"] || [nonEmpty[0] hasPrefix:@"CQ_"]) {
        self.isCQ = YES;
        self.messageType = TX500FT8MessageTypeCQ;
        self.targetCall = @"CQ";

        if (nonEmpty.count >= 2) {
            // CQ [MODIFIER] CALLSIGN [GRID]
            if (nonEmpty.count == 2) {
                self.callerCall = nonEmpty[1];
            } else if (nonEmpty.count >= 3) {
                // Check if index 1 is a modifier like DX, NA, AS, FD, etc.
                if (nonEmpty[1].length <= 3 && ![self isValidCallsign:nonEmpty[1]]) {
                    self.callerCall = nonEmpty[2];
                    if (nonEmpty.count >= 4 && [self isValidGrid:nonEmpty[3]]) {
                        self.grid = nonEmpty[3];
                    }
                } else {
                    self.callerCall = nonEmpty[1];
                    if ([self isValidGrid:nonEmpty[2]]) {
                        self.grid = nonEmpty[2];
                    }
                }
            }
        }
    } else if (nonEmpty.count >= 2) {
        // Standard directed message: TARGET CALLSIGN [PAYLOAD]
        self.targetCall = nonEmpty[0];
        self.callerCall = nonEmpty[1];

        if (myCall.length > 0 && [self.targetCall isEqualToString:myCall]) {
            self.isDirectedToMe = YES;
        }
        if (nonEmpty.count >= 3) {
            NSString *p3 = nonEmpty[2];
            if ([p3 isEqualToString:@"73"]) {
                self.messageType = TX500FT8MessageType73;
            } else if ([p3 isEqualToString:@"RR73"]) {
                self.messageType = TX500FT8MessageTypeRR73;
            } else if ([p3 isEqualToString:@"RRR"]) {
                self.messageType = TX500FT8MessageTypeRRR;
            } else if ([p3 hasPrefix:@"R+"] || [p3 hasPrefix:@"R-"]) {
                self.messageType = TX500FT8MessageTypeRogerReport;
                self.isRoger = YES;
                self.snrReport = [p3 substringFromIndex:1];
            } else if ([p3 hasPrefix:@"+"] || [p3 hasPrefix:@"-"]) {
                self.messageType = TX500FT8MessageTypeReport;
                self.snrReport = p3;
            } else if ([self isValidGrid:p3]) {
                self.messageType = TX500FT8MessageTypeReplyGrid;
                self.grid = p3;
            } else {
                self.messageType = TX500FT8MessageTypeFreeText;
            }
        } else {
            self.messageType = TX500FT8MessageTypeReplyGrid;
        }
    }

    // A locally transmitted frame can be decoded back through the audio path.
    // Mark it for every message type, including CQ, while preserving replies
    // whose target (rather than origin) is this station.
    if (myCall.length > 0 && [self.callerCall isEqualToString:myCall]) {
        self.isMyTransmission = YES;
    }

    // Resolve Country & Flag
    NSString *callForDXCC = self.callerCall;
    if (self.isMyTransmission && self.targetCall.length > 0 && ![self.targetCall isEqualToString:@"CQ"]) {
        callForDXCC = self.targetCall;
    }
    if (callForDXCC.length > 0) {
        self.countryName = [TX500FT8Message countryNameForCallsign:callForDXCC];
        self.countryFlag = [TX500FT8Message countryFlagForCallsign:callForDXCC];
        self.continent = [TX500FT8Message continentForCallsign:callForDXCC];
    }

    // Calculate Distance & Bearing if grid is known
    if (self.grid.length >= 4 && myGrid.length >= 4) {
        self.distanceKm = [TX500FT8Message distanceKmFromGrid:myGrid toGrid:self.grid];
        self.bearingDeg = [TX500FT8Message bearingDegFromGrid:myGrid toGrid:self.grid];
    }
}

- (BOOL)isValidCallsign:(NSString *)str {
    if (str.length < 3 || str.length > 11) return NO;
    BOOL hasDigit = NO;
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        if (c >= '0' && c <= '9') hasDigit = YES;
        else if ((c >= 'A' && c <= 'Z') || c == '/') { /* valid */ }
        else return NO;
    }
    return hasDigit;
}

- (BOOL)isValidGrid:(NSString *)str {
    if (str.length != 4 && str.length != 6) return NO;
    unichar c0 = [str characterAtIndex:0];
    unichar c1 = [str characterAtIndex:1];
    unichar c2 = [str characterAtIndex:2];
    unichar c3 = [str characterAtIndex:3];

    if (c0 < 'A' || c0 > 'R' || c1 < 'A' || c1 > 'R') return NO;
    if (c2 < '0' || c2 > '9' || c3 < '0' || c3 > '9') return NO;

    if (str.length == 6) {
        unichar c4 = [str characterAtIndex:4];
        unichar c5 = [str characterAtIndex:5];
        if (c4 < 'A' || c4 > 'X' || c5 < 'A' || c5 > 'X') return NO;
    }
    return YES;
}

#pragma mark - Maidenhead Coordinates & Distance

+ (BOOL)parseMaidenhead:(NSString *)grid outLat:(double *)outLat outLon:(double *)outLon {
    if (!grid || (grid.length != 4 && grid.length != 6)) return NO;
    NSString *g = [grid uppercaseString];

    unichar f_lon = [g characterAtIndex:0];
    unichar f_lat = [g characterAtIndex:1];
    unichar s_lon = [g characterAtIndex:2];
    unichar s_lat = [g characterAtIndex:3];

    if (f_lon < 'A' || f_lon > 'R' || f_lat < 'A' || f_lat > 'R') return NO;
    if (s_lon < '0' || s_lon > '9' || s_lat < '0' || s_lat > '9') return NO;

    double lon = (f_lon - 'A') * 20.0 - 180.0 + (s_lon - '0') * 2.0 + 1.0;
    double lat = (f_lat - 'A') * 10.0 - 90.0 + (s_lat - '0') * 1.0 + 0.5;

    if (g.length == 6) {
        unichar ss_lon = [g characterAtIndex:4];
        unichar ss_lat = [g characterAtIndex:5];
        if (ss_lon >= 'A' && ss_lon <= 'X' && ss_lat >= 'A' && ss_lat <= 'X') {
            lon = (f_lon - 'A') * 20.0 - 180.0 + (s_lon - '0') * 2.0 + (ss_lon - 'A' + 0.5) * (5.0 / 60.0);
            lat = (f_lat - 'A') * 10.0 - 90.0 + (s_lat - '0') * 1.0 + (ss_lat - 'A' + 0.5) * (2.5 / 60.0);
        }
    }

    if (outLon) *outLon = lon;
    if (outLat) *outLat = lat;
    return YES;
}

+ (double)distanceKmFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid {
    double lat1 = 0, lon1 = 0, lat2 = 0, lon2 = 0;
    if (![self parseMaidenhead:fromGrid outLat:&lat1 outLon:&lon1]) return -1.0;
    if (![self parseMaidenhead:toGrid outLat:&lat2 outLon:&lon2]) return -1.0;

    double dLat = Deg2Rad(lat2 - lat1);
    double dLon = Deg2Rad(lon2 - lon1);

    double a = sin(dLat / 2.0) * sin(dLat / 2.0) +
               cos(Deg2Rad(lat1)) * cos(Deg2Rad(lat2)) *
               sin(dLon / 2.0) * sin(dLon / 2.0);
    double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    double earthRadiusKm = 6371.0;
    return earthRadiusKm * c;
}

+ (double)bearingDegFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid {
    double lat1 = 0, lon1 = 0, lat2 = 0, lon2 = 0;
    if (![self parseMaidenhead:fromGrid outLat:&lat1 outLon:&lon1]) return -1.0;
    if (![self parseMaidenhead:toGrid outLat:&lat2 outLon:&lon2]) return -1.0;

    double phi1 = Deg2Rad(lat1);
    double phi2 = Deg2Rad(lat2);
    double deltaLambda = Deg2Rad(lon2 - lon1);

    double y = sin(deltaLambda) * cos(phi2);
    double x = cos(phi1) * sin(phi2) - sin(phi1) * cos(phi2) * cos(deltaLambda);
    double theta = atan2(y, x);
    double bearing = fmod(Rad2Deg(theta) + 360.0, 360.0);
    return bearing;
}

#pragma mark - Country & Flag Prefix Database

typedef struct {
    const char *prefix;
    const char *country;
    const char *flag;
} DXCCPrefixEntry;

// Sorted by descending specificity / prefix length so longest match wins
static const DXCCPrefixEntry s_dxccPrefixes[] = {
    // 4-char and 3-char specific prefixes
    {"1A0",  "SMOM", "🇲🇹"},
    {"4U1",  "United Nations", "🇺🇳"},
    {"AL7",  "Alaska", "🇺🇸"},
    {"AH6",  "Hawaii", "🇺🇸"},
    {"KH6",  "Hawaii", "🇺🇸"},
    {"NH6",  "Hawaii", "🇺🇸"},
    {"WH6",  "Hawaii", "🇺🇸"},
    {"KP4",  "Puerto Rico", "🇵🇷"},
    {"NP4",  "Puerto Rico", "🇵🇷"},
    {"WP4",  "Puerto Rico", "🇵🇷"},
    {"KP2",  "Virgin Islands", "🇻🇮"},
    {"NP2",  "Virgin Islands", "🇻🇮"},
    {"WP2",  "Virgin Islands", "🇻🇮"},
    {"KH0",  "Mariana Islands", "🇲🇵"},
    {"KH2",  "Guam", "🇬🇺"},
    {"PJ2",  "Curacao", "🇨🇼"},
    {"PJ4",  "Bonaire", "🇧🇶"},
    {"PJ7",  "Sint Maarten", "🇸🇽"},
    {"PJ5",  "Saba & St. Eustatius", "🇧🇶"},
    {"PJ6",  "Saba & St. Eustatius", "🇧🇶"},
    {"ZC4",  "UK Sovereign Bases (Cyprus)", "🇨🇾"},
    {"HB0",  "Liechtenstein", "🇱🇮"},
    {"HB9",  "Switzerland", "🇨🇭"},
    {"OH0",  "Aland Islands", "🇦🇽"},
    {"SV9",  "Crete", "🇬🇷"},
    {"SV5",  "Dodecanese", "🇬🇷"},
    {"EA6",  "Balearic Islands", "🇪🇸"},
    {"EA8",  "Canary Islands", "🇪🇸"},
    {"EA9",  "Ceuta & Melilla", "🇪🇸"},
    {"CT3",  "Madeira", "🇵🇹"},
    {"CS3",  "Madeira", "🇵🇹"},
    {"VR2",  "Hong Kong", "🇭🇰"},
    {"XX9",  "Macau", "🇲🇴"},
    {"3D2",  "Fiji", "🇫🇯"},
    {"3B8",  "Mauritius", "🇲🇺"},

    // Kaliningrad
    {"RA2",  "Kaliningrad", "🇷🇺"},
    {"UA2",  "Kaliningrad", "🇷🇺"},
    {"UB2",  "Kaliningrad", "🇷🇺"},

    // Asiatic Russia (R8, R9, R0, UA8, UA9, UA0, etc.)
    {"RA8", "Asiatic Russia", "🇷🇺"}, {"RA9", "Asiatic Russia", "🇷🇺"}, {"RA0", "Asiatic Russia", "🇷🇺"},
    {"RC8", "Asiatic Russia", "🇷🇺"}, {"RC9", "Asiatic Russia", "🇷🇺"}, {"RC0", "Asiatic Russia", "🇷🇺"},
    {"RD8", "Asiatic Russia", "🇷🇺"}, {"RD9", "Asiatic Russia", "🇷🇺"}, {"RD0", "Asiatic Russia", "🇷🇺"},
    {"RE8", "Asiatic Russia", "🇷🇺"}, {"RE9", "Asiatic Russia", "🇷🇺"}, {"RE0", "Asiatic Russia", "🇷🇺"},
    {"RF8", "Asiatic Russia", "🇷🇺"}, {"RF9", "Asiatic Russia", "🇷🇺"}, {"RF0", "Asiatic Russia", "🇷🇺"},
    {"RG8", "Asiatic Russia", "🇷🇺"}, {"RG9", "Asiatic Russia", "🇷🇺"}, {"RG0", "Asiatic Russia", "🇷🇺"},
    {"RI8", "Asiatic Russia", "🇷🇺"}, {"RI9", "Asiatic Russia", "🇷🇺"}, {"RI0", "Asiatic Russia", "🇷🇺"},
    {"RJ8", "Asiatic Russia", "🇷🇺"}, {"RJ9", "Asiatic Russia", "🇷🇺"}, {"RJ0", "Asiatic Russia", "🇷🇺"},
    {"RK8", "Asiatic Russia", "🇷🇺"}, {"RK9", "Asiatic Russia", "🇷🇺"}, {"RK0", "Asiatic Russia", "🇷🇺"},
    {"RL8", "Asiatic Russia", "🇷🇺"}, {"RL9", "Asiatic Russia", "🇷🇺"}, {"RL0", "Asiatic Russia", "🇷🇺"},
    {"RM8", "Asiatic Russia", "🇷🇺"}, {"RM9", "Asiatic Russia", "🇷🇺"}, {"RM0", "Asiatic Russia", "🇷🇺"},
    {"RN8", "Asiatic Russia", "🇷🇺"}, {"RN9", "Asiatic Russia", "🇷🇺"}, {"RN0", "Asiatic Russia", "🇷🇺"},
    {"RO8", "Asiatic Russia", "🇷🇺"}, {"RO9", "Asiatic Russia", "🇷🇺"}, {"RO0", "Asiatic Russia", "🇷🇺"},
    {"RP8", "Asiatic Russia", "🇷🇺"}, {"RP9", "Asiatic Russia", "🇷🇺"}, {"RP0", "Asiatic Russia", "🇷🇺"},
    {"RQ8", "Asiatic Russia", "🇷🇺"}, {"RQ9", "Asiatic Russia", "🇷🇺"}, {"RQ0", "Asiatic Russia", "🇷🇺"},
    {"RR8", "Asiatic Russia", "🇷🇺"}, {"RR9", "Asiatic Russia", "🇷🇺"}, {"RR0", "Asiatic Russia", "🇷🇺"},
    {"RS8", "Asiatic Russia", "🇷🇺"}, {"RS9", "Asiatic Russia", "🇷🇺"}, {"RS0", "Asiatic Russia", "🇷🇺"},
    {"RT8", "Asiatic Russia", "🇷🇺"}, {"RT9", "Asiatic Russia", "🇷🇺"}, {"RT0", "Asiatic Russia", "🇷🇺"},
    {"RU8", "Asiatic Russia", "🇷🇺"}, {"RU9", "Asiatic Russia", "🇷🇺"}, {"RU0", "Asiatic Russia", "🇷🇺"},
    {"RV8", "Asiatic Russia", "🇷🇺"}, {"RV9", "Asiatic Russia", "🇷🇺"}, {"RV0", "Asiatic Russia", "🇷🇺"},
    {"RW8", "Asiatic Russia", "🇷🇺"}, {"RW9", "Asiatic Russia", "🇷🇺"}, {"RW0", "Asiatic Russia", "🇷🇺"},
    {"RX8", "Asiatic Russia", "🇷🇺"}, {"RX9", "Asiatic Russia", "🇷🇺"}, {"RX0", "Asiatic Russia", "🇷🇺"},
    {"RY8", "Asiatic Russia", "🇷🇺"}, {"RY9", "Asiatic Russia", "🇷🇺"}, {"RY0", "Asiatic Russia", "🇷🇺"},
    {"RZ8", "Asiatic Russia", "🇷🇺"}, {"RZ9", "Asiatic Russia", "🇷🇺"}, {"RZ0", "Asiatic Russia", "🇷🇺"},
    {"UA8", "Asiatic Russia", "🇷🇺"}, {"UA9", "Asiatic Russia", "🇷🇺"}, {"UA0", "Asiatic Russia", "🇷🇺"},
    {"UB8", "Asiatic Russia", "🇷🇺"}, {"UB9", "Asiatic Russia", "🇷🇺"}, {"UB0", "Asiatic Russia", "🇷🇺"},
    {"UC8", "Asiatic Russia", "🇷🇺"}, {"UC9", "Asiatic Russia", "🇷🇺"}, {"UC0", "Asiatic Russia", "🇷🇺"},
    {"UD8", "Asiatic Russia", "🇷🇺"}, {"UD9", "Asiatic Russia", "🇷🇺"}, {"UD0", "Asiatic Russia", "🇷🇺"},
    {"UE8", "Asiatic Russia", "🇷🇺"}, {"UE9", "Asiatic Russia", "🇷🇺"}, {"UE0", "Asiatic Russia", "🇷🇺"},
    {"UF8", "Asiatic Russia", "🇷🇺"}, {"UF9", "Asiatic Russia", "🇷🇺"}, {"UF0", "Asiatic Russia", "🇷🇺"},
    {"UG8", "Asiatic Russia", "🇷🇺"}, {"UG9", "Asiatic Russia", "🇷🇺"}, {"UG0", "Asiatic Russia", "🇷🇺"},
    {"UH8", "Asiatic Russia", "🇷🇺"}, {"UH9", "Asiatic Russia", "🇷🇺"}, {"UH0", "Asiatic Russia", "🇷🇺"},
    {"UI8", "Asiatic Russia", "🇷🇺"}, {"UI9", "Asiatic Russia", "🇷🇺"}, {"UI0", "Asiatic Russia", "🇷🇺"},
    {"R8",  "Asiatic Russia", "🇷🇺"}, {"R9",  "Asiatic Russia", "🇷🇺"}, {"R0",  "Asiatic Russia", "🇷🇺"},

    // European Russia
    {"RA", "European Russia", "🇷🇺"}, {"RC", "European Russia", "🇷🇺"}, {"RD", "European Russia", "🇷🇺"},
    {"RE", "European Russia", "🇷🇺"}, {"RF", "European Russia", "🇷🇺"}, {"RG", "European Russia", "🇷🇺"},
    {"RI", "European Russia", "🇷🇺"}, {"RJ", "European Russia", "🇷🇺"}, {"RK", "European Russia", "🇷🇺"},
    {"RL", "European Russia", "🇷🇺"}, {"RM", "European Russia", "🇷🇺"}, {"RN", "European Russia", "🇷🇺"},
    {"RO", "European Russia", "🇷🇺"}, {"RP", "European Russia", "🇷🇺"}, {"RQ", "European Russia", "🇷🇺"},
    {"RR", "European Russia", "🇷🇺"}, {"RS", "European Russia", "🇷🇺"}, {"RT", "European Russia", "🇷🇺"},
    {"RU", "European Russia", "🇷🇺"}, {"RV", "European Russia", "🇷🇺"}, {"RW", "European Russia", "🇷🇺"},
    {"RX", "European Russia", "🇷🇺"}, {"RY", "European Russia", "🇷🇺"}, {"RZ", "European Russia", "🇷🇺"},
    {"UA", "European Russia", "🇷🇺"}, {"UB", "European Russia", "🇷🇺"}, {"UC", "European Russia", "🇷🇺"},
    {"UD", "European Russia", "🇷🇺"}, {"UE", "European Russia", "🇷🇺"}, {"UF", "European Russia", "🇷🇺"},
    {"UG", "European Russia", "🇷🇺"}, {"UH", "European Russia", "🇷🇺"}, {"UI", "European Russia", "🇷🇺"},
    {"R1", "European Russia", "🇷🇺"}, {"R2", "European Russia", "🇷🇺"}, {"R3", "European Russia", "🇷🇺"},
    {"R4", "European Russia", "🇷🇺"}, {"R5", "European Russia", "🇷🇺"}, {"R6", "European Russia", "🇷🇺"},
    {"R7", "European Russia", "🇷🇺"}, {"R",  "European Russia", "🇷🇺"},

    // UK & Crown Dependencies
    {"GI",  "Northern Ireland", "🇬🇧"},
    {"MI",  "Northern Ireland", "🇬🇧"},
    {"2I",  "Northern Ireland", "🇬🇧"},
    {"GM",  "Scotland", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"},
    {"MM",  "Scotland", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"},
    {"2M",  "Scotland", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"},
    {"GW",  "Wales", "🏴󠁧󠁢󠁷󠁬󠁳󠁿"},
    {"MW",  "Wales", "🏴󠁧󠁢󠁷󠁬󠁳󠁿"},
    {"2W",  "Wales", "🏴󠁧󠁢󠁷󠁬󠁳󠁿"},
    {"GD",  "Isle of Man", "🇮🇲"},
    {"MD",  "Isle of Man", "🇮🇲"},
    {"2D",  "Isle of Man", "🇮🇲"},
    {"GJ",  "Jersey", "🇯🇪"},
    {"MJ",  "Jersey", "🇯🇪"},
    {"2J",  "Jersey", "🇯🇪"},
    {"GU",  "Guernsey", "🇬🇬"},
    {"MU",  "Guernsey", "🇬🇬"},
    {"2U",  "Guernsey", "🇬🇬"},
    {"G",   "England", "🇬🇧"},
    {"M",   "England", "🇬🇧"},
    {"2E",  "England", "🇬🇧"},

    // Netherlands
    {"PA", "Netherlands", "🇳🇱"}, {"PB", "Netherlands", "🇳🇱"}, {"PC", "Netherlands", "🇳🇱"},
    {"PD", "Netherlands", "🇳🇱"}, {"PE", "Netherlands", "🇳🇱"}, {"PF", "Netherlands", "🇳🇱"},
    {"PG", "Netherlands", "🇳🇱"}, {"PH", "Netherlands", "🇳🇱"}, {"PI", "Netherlands", "🇳🇱"},

    // Italy
    {"IS0", "Sardinia", "🇮🇹"},
    {"IT9", "Sicily", "🇮🇹"},
    {"II",  "Italy", "🇮🇹"},
    {"IK",  "Italy", "🇮🇹"},
    {"IZ",  "Italy", "🇮🇹"},
    {"IU",  "Italy", "🇮🇹"},
    {"IS",  "Italy", "🇮🇹"},
    {"I",   "Italy", "🇮🇹"},

    // China
    {"BG", "China", "🇨🇳"}, {"BA", "China", "🇨🇳"}, {"BD", "China", "🇨🇳"}, {"BH", "China", "🇨🇳"},
    {"BI", "China", "🇨🇳"}, {"BJ", "China", "🇨🇳"}, {"BL", "China", "🇨🇳"}, {"BM", "China", "🇨🇳"},
    {"BN", "China", "🇨🇳"}, {"BO", "China", "🇨🇳"}, {"BP", "China", "🇨🇳"}, {"BQ", "China", "🇨🇳"},
    {"BR", "China", "🇨🇳"}, {"BS", "China", "🇨🇳"}, {"BT", "China", "🇨🇳"}, {"BY", "China", "🇨🇳"},
    {"B",  "China", "🇨🇳"},

    // Taiwan
    {"BV",  "Taiwan", "🇹🇼"},
    {"BX",  "Taiwan", "🇹🇼"},

    // Iran
    {"EP",  "Iran", "🇮🇷"},
    {"EQ",  "Iran", "🇮🇷"},
    {"9C",  "Iran", "🇮🇷"},

    // Japan
    {"JA", "Japan", "🇯🇵"}, {"JH", "Japan", "🇯🇵"}, {"JR", "Japan", "🇯🇵"}, {"JE", "Japan", "🇯🇵"},
    {"JF", "Japan", "🇯🇵"}, {"JG", "Japan", "🇯🇵"}, {"JI", "Japan", "🇯🇵"}, {"JJ", "Japan", "🇯🇵"},
    {"JK", "Japan", "🇯🇵"}, {"JL", "Japan", "🇯🇵"}, {"JM", "Japan", "🇯🇵"}, {"JN", "Japan", "🇯🇵"},
    {"JO", "Japan", "🇯🇵"}, {"JP", "Japan", "🇯🇵"}, {"JQ", "Japan", "🇯🇵"}, {"JS", "Japan", "🇯🇵"},
    {"7J", "Japan", "🇯🇵"}, {"7K", "Japan", "🇯🇵"}, {"7L", "Japan", "🇯🇵"}, {"7M", "Japan", "🇯🇵"},
    {"7N", "Japan", "🇯🇵"}, {"8J", "Japan", "🇯🇵"}, {"8K", "Japan", "🇯🇵"}, {"8L", "Japan", "🇯🇵"},
    {"8M", "Japan", "🇯🇵"}, {"8N", "Japan", "🇯🇵"}, {"7",  "Japan", "🇯🇵"},

    // USA
    {"KL", "Alaska", "🇺🇸"}, {"NL", "Alaska", "🇺🇸"}, {"WL", "Alaska", "🇺🇸"},
    {"AA", "United States", "🇺🇸"}, {"AB", "United States", "🇺🇸"}, {"AC", "United States", "🇺🇸"},
    {"AD", "United States", "🇺🇸"}, {"AE", "United States", "🇺🇸"}, {"AF", "United States", "🇺🇸"},
    {"AG", "United States", "🇺🇸"}, {"AH", "United States", "🇺🇸"}, {"AI", "United States", "🇺🇸"},
    {"AJ", "United States", "🇺🇸"}, {"AK", "United States", "🇺🇸"},
    {"W",  "United States", "🇺🇸"}, {"K",  "United States", "🇺🇸"}, {"N",  "United States", "🇺🇸"},

    // Canada
    {"VE", "Canada", "🇨🇦"}, {"VA", "Canada", "🇨🇦"}, {"VY", "Canada", "🇨🇦"}, {"VO", "Canada", "🇨🇦"},

    // Germany
    {"DL", "Germany", "🇩🇪"}, {"DJ", "Germany", "🇩🇪"}, {"DK", "Germany", "🇩🇪"},
    {"DF", "Germany", "🇩🇪"}, {"DG", "Germany", "🇩🇪"}, {"DH", "Germany", "🇩🇪"},
    {"DM", "Germany", "🇩🇪"}, {"DO", "Germany", "🇩🇪"}, {"DA", "Germany", "🇩🇪"},
    {"DB", "Germany", "🇩🇪"}, {"DC", "Germany", "🇩🇪"}, {"DD", "Germany", "🇩🇪"},
    {"DN", "Germany", "🇩🇪"}, {"DP", "Germany", "🇩🇪"},

    // France & Territories
    {"TK", "Corsica", "🇫🇷"},
    {"FM", "Martinique", "🇲🇶"},
    {"FG", "Guadeloupe", "🇬🇵"},
    {"FY", "French Guiana", "🇬🇫"},
    {"FR", "Reunion", "🇷🇪"},
    {"FS", "Saint Martin", "🇲🇫"},
    {"FJ", "Saint Barthelemy", "🇧🇱"},
    {"FK", "New Caledonia", "🇳🇨"},
    {"FO", "French Polynesia", "🇵🇫"},
    {"FW", "Wallis & Futuna", "🇼🇫"},
    {"F",  "France", "🇫🇷"}, {"TM", "France", "🇫🇷"},

    // Spain
    {"EA", "Spain", "🇪🇸"}, {"EB", "Spain", "🇪🇸"}, {"EC", "Spain", "🇪🇸"}, {"ED", "Spain", "🇪🇸"},
    {"EE", "Spain", "🇪🇸"}, {"EF", "Spain", "🇪🇸"}, {"EG", "Spain", "🇪🇸"}, {"EH", "Spain", "🇪🇸"},
    {"AM", "Spain", "🇪🇸"}, {"AN", "Spain", "🇪🇸"}, {"AO", "Spain", "🇪🇸"},

    // Portugal & Azores
    {"CU", "Azores", "🇵🇹"},
    {"CT", "Portugal", "🇵🇹"}, {"CS", "Portugal", "🇵🇹"}, {"CR", "Portugal", "🇵🇹"},

    // Ireland
    {"EI", "Ireland", "🇮🇪"}, {"EJ", "Ireland", "🇮🇪"},

    // Luxembourg, Malta, Monaco, San Marino, Vatican, Andorra, Gibraltar
    {"LX", "Luxembourg", "🇱🇺"},
    {"9H", "Malta", "🇲🇹"},
    {"3A", "Monaco", "🇲🇨"},
    {"T7", "San Marino", "🇸🇲"},
    {"HV", "Vatican City", "🇻🇦"},
    {"C3", "Andorra", "🇦🇩"},
    {"ZB", "Gibraltar", "🇬🇮"}, {"ZG", "Gibraltar", "🇬🇮"},

    // Ukraine
    {"UR", "Ukraine", "🇺🇦"}, {"US", "Ukraine", "🇺🇦"}, {"UT", "Ukraine", "🇺🇦"},
    {"UY", "Ukraine", "🇺🇦"}, {"UX", "Ukraine", "🇺🇦"}, {"UW", "Ukraine", "🇺🇦"},
    {"EM", "Ukraine", "🇺🇦"}, {"EN", "Ukraine", "🇺🇦"}, {"EO", "Ukraine", "🇺🇦"},

    // Poland
    {"SP", "Poland", "🇵🇱"}, {"SQ", "Poland", "🇵🇱"}, {"SN", "Poland", "🇵🇱"},
    {"SO", "Poland", "🇵🇱"}, {"3Z", "Poland", "🇵🇱"}, {"HF", "Poland", "🇵🇱"},

    // Czech & Slovakia
    {"OK", "Czech Republic", "🇨🇿"}, {"OL", "Czech Republic", "🇨🇿"},
    {"OM", "Slovakia", "🇸🇰"},

    // Hungary & Austria
    {"HA", "Hungary", "🇭🇺"}, {"HG", "Hungary", "🇭🇺"},
    {"OE", "Austria", "🇦🇹"},

    // Switzerland & Belgium
    {"HB", "Switzerland", "🇨🇭"},
    {"ON", "Belgium", "🇧🇪"}, {"OO", "Belgium", "🇧🇪"}, {"OP", "Belgium", "🇧🇪"},
    {"OR", "Belgium", "🇧🇪"}, {"OS", "Belgium", "🇧🇪"}, {"OT", "Belgium", "🇧🇪"},

    // Nordic
    {"JW", "Svalbard", "🇸🇯"}, {"JX", "Jan Mayen", "🇸🇯"},
    {"SM", "Sweden", "🇸🇪"}, {"SA", "Sweden", "🇸🇪"}, {"SK", "Sweden", "🇸🇪"}, {"SL", "Sweden", "🇸🇪"},
    {"LA", "Norway", "🇳🇴"}, {"LB", "Norway", "🇳🇴"}, {"LN", "Norway", "🇳🇴"},
    {"OH", "Finland", "🇫🇮"}, {"OG", "Finland", "🇫🇮"}, {"OF", "Finland", "🇫🇮"},
    {"OZ", "Denmark", "🇩🇰"}, {"OU", "Denmark", "🇩🇰"}, {"OX", "Greenland", "🇬🇱"},
    {"OY", "Faroe Islands", "🇫🇴"},
    {"TF", "Iceland", "🇮🇸"},

    // Baltic & Eastern Europe
    {"LY", "Lithuania", "🇱🇹"},
    {"YL", "Latvia", "🇱🇻"},
    {"ES", "Estonia", "🇪🇪"},
    {"EW", "Belarus", "🇧🇾"}, {"EU", "Belarus", "🇧🇾"}, {"EV", "Belarus", "🇧🇾"},
    {"ER", "Moldova", "🇲🇩"},
    {"LZ", "Bulgaria", "🇧🇬"},
    {"YO", "Romania", "🇷🇴"}, {"YP", "Romania", "🇷🇴"}, {"YR", "Romania", "🇷🇴"},
    {"YU", "Serbia", "🇷🇸"}, {"YT", "Serbia", "🇷🇸"},
    {"Z6", "Kosovo", "🇽🇰"},
    {"Z3", "North Macedonia", "🇲🇰"},
    {"ZA", "Albania", "🇦🇱"},
    {"4O", "Montenegro", "🇲🇪"},
    {"E7", "Bosnia & Herzegovina", "🇧🇦"},
    {"9A", "Croatia", "🇭🇷"},
    {"S5", "Slovenia", "🇸🇮"},

    // Greece & Turkey & Cyprus
    {"SV", "Greece", "🇬🇷"}, {"SW", "Greece", "🇬🇷"}, {"SX", "Greece", "🇬🇷"},
    {"TA", "Turkey", "🇹🇷"}, {"TB", "Turkey", "🇹🇷"}, {"TC", "Turkey", "🇹🇷"}, {"YM", "Turkey", "🇹🇷"},
    {"5B", "Cyprus", "🇨🇾"}, {"C4", "Cyprus", "🇨🇾"},

    // Middle East & Caucasus
    {"EK", "Armenia", "🇦🇲"},
    {"4J", "Azerbaijan", "🇦🇿"}, {"4K", "Azerbaijan", "🇦🇿"},
    {"4L", "Georgia", "🇬🇪"},
    {"HZ", "Saudi Arabia", "🇸🇦"}, {"7Z", "Saudi Arabia", "🇸🇦"}, {"8Z", "Saudi Arabia", "🇸🇦"},
    {"A6", "United Arab Emirates", "🇦🇪"},
    {"A7", "Qatar", "🇶🇦"},
    {"A9", "Bahrain", "🇧🇭"},
    {"9K", "Kuwait", "🇰🇼"},
    {"4X", "Israel", "🇮🇱"}, {"4Z", "Israel", "🇮🇱"},
    {"JY", "Jordan", "🇯🇴"},
    {"OD", "Lebanon", "🇱🇧"},
    {"YK", "Syria", "🇸🇾"},
    {"YI", "Iraq", "🇮🇶"},
    {"A4", "Oman", "🇴🇲"},
    {"7O", "Yemen", "🇾🇪"},

    // Central & South Asia
    {"UN", "Kazakhstan", "🇰🇿"}, {"UP", "Kazakhstan", "🇰🇿"},
    {"UK", "Uzbekistan", "🇺🇿"}, {"UJ", "Uzbekistan", "🇺🇿"},
    {"EX", "Kyrgyzstan", "🇰🇬"},
    {"EY", "Tajikistan", "🇹🇯"},
    {"EZ", "Turkmenistan", "🇹🇲"},
    {"YA", "Afghanistan", "🇦🇫"},
    {"HL", "South Korea", "🇰🇷"}, {"DS", "South Korea", "🇰🇷"}, {"6K", "South Korea", "🇰🇷"},
    {"VU", "India", "🇮🇳"}, {"AT", "India", "🇮🇳"},
    {"AP", "Pakistan", "🇵🇰"},
    {"4S", "Sri Lanka", "🇱🇰"},
    {"S2", "Bangladesh", "🇧🇩"},
    {"9N", "Nepal", "🇳🇵"},
    {"A5", "Bhutan", "🇧🇹"},
    {"8Q", "Maldives", "🇲🇻"},
    {"JT", "Mongolia", "🇲🇳"},

    // Southeast Asia
    {"HS", "Thailand", "🇹🇭"}, {"E2", "Thailand", "🇹🇭"},
    {"9M", "Malaysia", "🇲🇾"}, {"9W", "Malaysia", "🇲🇾"},
    {"9V", "Singapore", "🇸🇬"},
    {"V8", "Brunei", "🇧🇳"},
    {"YB", "Indonesia", "🇮🇩"}, {"YC", "Indonesia", "🇮🇩"}, {"YD", "Indonesia", "🇮🇩"},
    {"DU", "Philippines", "🇵🇭"}, {"DV", "Philippines", "🇵🇭"}, {"DW", "Philippines", "🇵🇭"},
    {"XV", "Vietnam", "🇻🇳"}, {"3W", "Vietnam", "🇻🇳"},
    {"XW", "Laos", "🇱🇦"},
    {"XU", "Cambodia", "🇰🇭"},
    {"XZ", "Myanmar", "🇲🇲"},

    // Oceania
    {"VK", "Australia", "🇦🇺"}, {"AX", "Australia", "🇦🇺"},
    {"ZL", "New Zealand", "🇳🇿"}, {"ZM", "New Zealand", "🇳🇿"},
    {"P2", "Papua New Guinea", "🇵🇬"},
    {"H4", "Solomon Islands", "🇸🇧"},
    {"YJ", "Vanuatu", "🇻🇺"},
    {"5W", "Samoa", "🇼🇸"},
    {"A3", "Tonga", "🇹🇴"},

    // Africa
    {"ZS", "South Africa", "🇿🇦"}, {"ZR", "South Africa", "🇿🇦"}, {"ZT", "South Africa", "🇿🇦"},
    {"CN", "Morocco", "🇲🇦"},
    {"7X", "Algeria", "🇩🇿"},
    {"3V", "Tunisia", "🇹🇳"},
    {"SU", "Egypt", "🇪🇬"},
    {"5A", "Libya", "🇱🇾"},
    {"ST", "Sudan", "🇸🇩"},
    {"ET", "Ethiopia", "🇪🇹"},
    {"5Z", "Kenya", "🇰🇪"},
    {"5H", "Tanzania", "🇹🇿"},
    {"5X", "Uganda", "🇺🇬"},
    {"5N", "Nigeria", "🇳🇬"},
    {"9G", "Ghana", "🇬🇭"},
    {"6V", "Senegal", "🇸🇳"},
    {"TU", "Ivory Coast", "🇨🇮"},
    {"D2", "Angola", "🇦🇴"},
    {"C9", "Mozambique", "🇲🇿"},
    {"Z2", "Zimbabwe", "🇿🇼"},
    {"9J", "Zambia", "🇿🇲"},
    {"A2", "Botswana", "🇧🇼"},
    {"V5", "Namibia", "🇳🇦"},
    {"5R", "Madagascar", "🇲🇬"},
    {"S7", "Seychelles", "🇸🇨"},

    // South & Central America & Caribbean
    {"PY", "Brazil", "🇧🇷"}, {"PP", "Brazil", "🇧🇷"}, {"PR", "Brazil", "🇧🇷"}, {"PU", "Brazil", "🇧🇷"},
    {"LU", "Argentina", "🇦🇷"}, {"LW", "Argentina", "🇦🇷"}, {"AY", "Argentina", "🇦🇷"},
    {"CE", "Chile", "🇨🇱"}, {"CA", "Chile", "🇨🇱"}, {"CB", "Chile", "🇨🇱"}, {"XQ", "Chile", "🇨🇱"},
    {"CX", "Uruguay", "🇺🇾"}, {"CV", "Uruguay", "🇺🇾"},
    {"OA", "Peru", "🇵🇪"},
    {"HK", "Colombia", "🇨🇴"}, {"HJ", "Colombia", "🇨🇴"},
    {"YV", "Venezuela", "🇻🇪"}, {"YY", "Venezuela", "🇻🇪"},
    {"ZP", "Paraguay", "🇵🇾"},
    {"CP", "Bolivia", "🇧🇴"},
    {"HC", "Ecuador", "🇪🇨"},
    {"8R", "Guyana", "🇬🇾"},
    {"PZ", "Suriname", "🇸🇷"},
    {"XE", "Mexico", "🇲🇽"}, {"XF", "Mexico", "🇲🇽"}, {"4A", "Mexico", "🇲🇽"},
    {"TI", "Costa Rica", "🇨🇷"},
    {"HP", "Panama", "🇵🇦"},
    {"TG", "Guatemala", "🇬🇹"},
    {"YS", "El Salvador", "🇸🇻"},
    {"HR", "Honduras", "🇭🇳"},
    {"YN", "Nicaragua", "🇳🇮"},
    {"HI", "Dominican Republic", "🇩🇴"},
    {"HH", "Haiti", "🇭🇹"},
    {"CO", "Cuba", "🇨🇺"}, {"CM", "Cuba", "🇨🇺"},
    {"ZF", "Cayman Islands", "🇰🇾"},
    {"P4", "Aruba", "🇦🇼"},
    {"9Y", "Trinidad & Tobago", "🇹🇹"},
    {"8P", "Barbados", "🇧🇧"},
    {"6Y", "Jamaica", "🇯🇲"},
    {"C6", "Bahamas", "🇧🇸"},
    {"V3", "Belize", "🇧🇿"},
    {"VP9", "Bermuda", "🇧🇲"},

    {NULL, NULL, NULL}
};

static NSString *NormalizeCallsignForPrefix(NSString *call) {
    if (!call || call.length == 0) return @"";
    NSString *c = [call.uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([c containsString:@"/"]) {
        NSArray<NSString *> *parts = [c componentsSeparatedByString:@"/"];
        if (parts.count == 2) {
            NSString *p0 = parts[0];
            NSString *p1 = parts[1];
            if (p1.length <= 2 || [p1 isEqualToString:@"QRP"] || [p1 isEqualToString:@"LGT"]) {
                return p0; // Suffix like /P, /M, /1, /QRP
            } else if (p0.length <= 3 && [p0 rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) {
                return p0; // Prefix like SV9 or EA8 or KH6
            } else if (p0.length >= p1.length) {
                return p0;
            } else {
                return p1;
            }
        }
    }
    return c;
}

+ (const DXCCPrefixEntry *)lookupDXCCForCallsign:(NSString *)call {
    if (!call || call.length == 0) return NULL;
    NSString *c = NormalizeCallsignForPrefix(call);
    if (c.length == 0) return NULL;

    for (int i = 0; s_dxccPrefixes[i].prefix != NULL; i++) {
        NSString *pfx = [NSString stringWithUTF8String:s_dxccPrefixes[i].prefix];
        if ([c hasPrefix:pfx]) {
            return &s_dxccPrefixes[i];
        }
    }
    return NULL;
}

+ (NSString *)countryNameForCallsign:(NSString *)call {
    const DXCCPrefixEntry *entry = [self lookupDXCCForCallsign:call];
    if (entry && entry->country) {
        return [NSString stringWithUTF8String:entry->country];
    }
    return @"International";
}

+ (NSString *)countryFlagForCallsign:(NSString *)call {
    const DXCCPrefixEntry *entry = [self lookupDXCCForCallsign:call];
    if (entry && entry->flag) {
        return [NSString stringWithUTF8String:entry->flag];
    }
    return @"🌐";
}

+ (NSString *)continentForCallsign:(NSString *)call {
    NSString *country = [self countryNameForCallsign:call];
    if (!country || [country isEqualToString:@"International"]) return @"";

    static NSDictionary<NSString *, NSString *> *s_countryContinents = nil;
    static dispatch_once_t s_once;
    dispatch_once(&s_once, ^{
        s_countryContinents = @{
            @"United States": @"NA", @"Canada": @"NA", @"Mexico": @"NA", @"Alaska": @"NA", @"Hawaii": @"OC",
            @"Germany": @"EU", @"Italy": @"EU", @"France": @"EU", @"Spain": @"EU", @"United Kingdom": @"EU",
            @"England": @"EU", @"Scotland": @"EU", @"Wales": @"EU", @"Northern Ireland": @"EU",
            @"Netherlands": @"EU", @"Belgium": @"EU", @"Switzerland": @"EU", @"Austria": @"EU",
            @"European Russia": @"EU", @"Poland": @"EU", @"Czech Republic": @"EU", @"Slovakia": @"EU",
            @"Hungary": @"EU", @"Sweden": @"EU", @"Norway": @"EU", @"Finland": @"EU", @"Denmark": @"EU",
            @"Greece": @"EU", @"Portugal": @"EU", @"Ireland": @"EU", @"Romania": @"EU", @"Bulgaria": @"EU",
            @"Japan": @"AS", @"China": @"AS", @"Iran": @"AS", @"Asiatic Russia": @"AS", @"South Korea": @"AS",
            @"India": @"AS", @"Taiwan": @"AS", @"Thailand": @"AS", @"Israel": @"AS", @"Turkey": @"AS",
            @"Australia": @"OC", @"New Zealand": @"OC", @"Indonesia": @"OC", @"Philippines": @"OC",
            @"Brazil": @"SA", @"Argentina": @"SA", @"Chile": @"SA", @"Colombia": @"SA", @"Peru": @"SA",
            @"South Africa": @"AF", @"Egypt": @"AF", @"Morocco": @"AF", @"Kenya": @"AF"
        };
    });
    NSString *cont = s_countryContinents[country];
    return cont ?: @"";
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)allDXCCEntities {
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *entitiesByName = [NSMutableDictionary dictionary];
    for (int i = 0; s_dxccPrefixes[i].prefix != NULL; i++) {
        NSString *cName = [NSString stringWithUTF8String:s_dxccPrefixes[i].country];
        NSString *flag = [NSString stringWithUTF8String:s_dxccPrefixes[i].flag];
        NSString *pfx = [NSString stringWithUTF8String:s_dxccPrefixes[i].prefix];
        if (!entitiesByName[cName]) {
            entitiesByName[cName] = @{
                @"country": cName,
                @"flag": flag ?: @"🌐",
                @"prefix": pfx ?: @""
            };
        }
    }
    NSArray<NSString *> *sortedKeys = [[entitiesByName allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *result = [NSMutableArray arrayWithCapacity:sortedKeys.count];
    for (NSString *k in sortedKeys) {
        [result addObject:entitiesByName[k]];
    }
    return result;
}

#pragma mark - Standard FT8 Transmit Message Generation

+ (NSString *)messageForPhase:(NSInteger)phase
                       myCall:(NSString *)myCall
                       myGrid:(NSString *)myGrid
                       dxCall:(NSString *)dxCall
                       dxGrid:(nullable NSString *)dxGrid
                     myReport:(nullable NSString *)myReport
                   rcvdReport:(nullable NSString *)rcvdReport {
    NSString *cMy = [myCall uppercaseString];
    NSString *gMy = [myGrid uppercaseString];
    NSString *cDx = [dxCall uppercaseString];
    (void)dxGrid;

    if (!myReport || myReport.length == 0) myReport = @"-10";
    if (!rcvdReport || rcvdReport.length == 0) rcvdReport = @"-10";

    // Format reports as +00 or -00
    int rptVal = [myReport intValue];
    NSString *formattedMyReport = [NSString stringWithFormat:@"%+03d", rptVal];

    switch (phase) {
        case 1: // Tx 1: HisCall MyCall Grid (Answer CQ)
            if (gMy.length >= 4) {
                return [NSString stringWithFormat:@"%@ %@ %@", cDx, cMy, [gMy substringToIndex:4]];
            } else {
                return [NSString stringWithFormat:@"%@ %@", cDx, cMy];
            }
        case 2: // Tx 2: HisCall MyCall Report (Send Signal Report)
            return [NSString stringWithFormat:@"%@ %@ %@", cDx, cMy, formattedMyReport];
        case 3: // Tx 3: HisCall MyCall R+Report (Roger + Send Signal Report)
            return [NSString stringWithFormat:@"%@ %@ R%@", cDx, cMy, formattedMyReport];
        case 4: // Tx 4: HisCall MyCall RR73 (or RRR)
            return [NSString stringWithFormat:@"%@ %@ RR73", cDx, cMy];
        case 5: // Tx 5: HisCall MyCall 73
            return [NSString stringWithFormat:@"%@ %@ 73", cDx, cMy];
        case 6: // Tx 6: CQ MyCall Grid
        default:
            if (gMy.length >= 4) {
                return [NSString stringWithFormat:@"CQ %@ %@", cMy, [gMy substringToIndex:4]];
            } else {
                return [NSString stringWithFormat:@"CQ %@", cMy];
            }
    }
}

#pragma mark - ADIF Generator

+ (NSString *)adifRecordForCall:(NSString *)dxCall
                           band:(NSString *)band
                         freqHz:(uint64_t)freqHz
                        rstSent:(NSString *)rstSent
                        rstRcvd:(NSString *)rstRcvd
                           grid:(nullable NSString *)grid
                           date:(NSDate *)date {
    return [self adifRecordForCall:dxCall band:band freqHz:freqHz rstSent:rstSent rstRcvd:rstRcvd grid:grid date:date mode:@"FT8"];
}

+ (NSString *)adifRecordForCall:(NSString *)dxCall
                           band:(NSString *)band
                         freqHz:(uint64_t)freqHz
                        rstSent:(NSString *)rstSent
                        rstRcvd:(NSString *)rstRcvd
                           grid:(nullable NSString *)grid
                           date:(NSDate *)date
                           mode:(nullable NSString *)mode {
    if (!date) date = [NSDate date];
    NSDateFormatter *dfDate = [[NSDateFormatter alloc] init];
    dfDate.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dfDate.dateFormat = @"yyyyMMdd";

    NSDateFormatter *dfTime = [[NSDateFormatter alloc] init];
    dfTime.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dfTime.dateFormat = @"HHmmss";

    NSString *qsoDate = [dfDate stringFromDate:date];
    NSString *timeOn = [dfTime stringFromDate:date];
    double freqMHz = (double)freqHz / 1000000.0;

    NSMutableString *adif = [NSMutableString string];
    [adif appendFormat:@"<CALL:%lu>%@ ", (unsigned long)dxCall.length, dxCall];
    [adif appendFormat:@"<QSO_DATE:%lu>%@ ", (unsigned long)qsoDate.length, qsoDate];
    [adif appendFormat:@"<TIME_ON:%lu>%@ ", (unsigned long)timeOn.length, timeOn];
    [adif appendFormat:@"<BAND:%lu>%@ ", (unsigned long)band.length, band];
    NSString *freqStr = [NSString stringWithFormat:@"%.6f", freqMHz];
    [adif appendFormat:@"<FREQ:%lu>%@ ", (unsigned long)freqStr.length, freqStr];
    if ([mode isEqualToString:@"FT4"]) {
        [adif appendString:@"<MODE:4>MFSK <SUBMODE:3>FT4 "];
    } else {
        [adif appendString:@"<MODE:3>FT8 "];
    }

    if (rstSent.length > 0) {
        [adif appendFormat:@"<RST_SENT:%lu>%@ ", (unsigned long)rstSent.length, rstSent];
    }
    if (rstRcvd.length > 0) {
        [adif appendFormat:@"<RST_RCVD:%lu>%@ ", (unsigned long)rstRcvd.length, rstRcvd];
    }
    if (grid && grid.length >= 4) {
        NSString *g = [grid uppercaseString];
        [adif appendFormat:@"<GRIDSQUARE:%lu>%@ ", (unsigned long)g.length, g];
    }

    NSString *myCall = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorCallsign"];
    if (myCall.length > 0) {
        [adif appendFormat:@"<STATION_CALLSIGN:%lu>%@ ", (unsigned long)myCall.length, myCall];
    }
    NSString *myGrid = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorGrid"];
    if (myGrid.length > 0) {
        [adif appendFormat:@"<MY_GRIDSQUARE:%lu>%@ ", (unsigned long)myGrid.length, myGrid];
    }
    NSString *myOp = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorName"];
    if (myOp.length > 0) {
        [adif appendFormat:@"<OPERATOR:%lu>%@ ", (unsigned long)myOp.length, myOp];
    }

    [adif appendString:@"<EOR>\n"];
    return adif;
}

- (NSString *)adifRecordWithMyCall:(NSString *)myCall myGrid:(NSString *)myGrid {
    NSString *call = self.callerCall ?: @"";
    NSString *rst = self.snrReport ?: [NSString stringWithFormat:@"%+d", (int)roundf(self.snrDb)];
    NSString *band = @"20m";
    uint64_t freq = 14074000;
    if ([self.mode isEqualToString:@"FT4"]) {
        freq = 14080000;
    }
    return [TX500FT8Message adifRecordForCall:call
                                         band:band
                                       freqHz:freq
                                      rstSent:rst
                                      rstRcvd:rst
                                         grid:self.grid
                                         date:self.timestamp ?: [NSDate date]
                                         mode:self.mode];
}

@end
