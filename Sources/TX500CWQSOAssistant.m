//
//  TX500CWQSOAssistant.m
//  Lab599 Utility
//
//  Intelligent Semi-Automated CW QSO Assistant & ADIF Logger
//

#import "TX500CWQSOAssistant.h"
#import "TX500LogbookManager.h"
#import "TX500CloudSyncEngine.h"

@implementation TX500CWHeardStation
- (instancetype)init {
    self = [super init];
    if (self) {
        _callsign = @"";
        _timestamp = [NSDate date];
        _count = 1;
    }
    return self;
}
@end

@implementation TX500QSOContact
- (instancetype)init {
    self = [super init];
    if (self) {
        _callsign = @"";
        _mode = @"CW";
        _rstSent = @"599";
        _rstRcvd = @"599";
        _name = @"";
        _qth = @"";
        _notes = @"";
        
        NSDateFormatter *dfDate = [NSDateFormatter new];
        dfDate.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dfDate.dateFormat = @"yyyyMMdd";
        _qsoDate = [dfDate stringFromDate:[NSDate date]];

        NSDateFormatter *dfTime = [NSDateFormatter new];
        dfTime.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dfTime.dateFormat = @"HHmmss";
        _timeOn = [dfTime stringFromDate:[NSDate date]];
    }
    return self;
}

- (NSString *)adifRecordString {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"<CALL:%lu>%@ ", (unsigned long)self.callsign.length, self.callsign.uppercaseString];
    [s appendFormat:@"<QSO_DATE:%lu>%@ ", (unsigned long)self.qsoDate.length, self.qsoDate];
    [s appendFormat:@"<TIME_ON:%lu>%@ ", (unsigned long)self.timeOn.length, self.timeOn];
    if (self.band.length > 0) [s appendFormat:@"<BAND:%lu>%@ ", (unsigned long)self.band.length, self.band.lowercaseString];
    if (self.frequencyMHz > 0.0) [s appendFormat:@"<FREQ:%.6f> ", self.frequencyMHz];
    [s appendString:@"<MODE:2>CW "];
    [s appendFormat:@"<RST_SENT:%lu>%@ ", (unsigned long)self.rstSent.length, self.rstSent];
    [s appendFormat:@"<RST_RCVD:%lu>%@ ", (unsigned long)self.rstRcvd.length, self.rstRcvd];
    if (self.name.length > 0) [s appendFormat:@"<NAME:%lu>%@ ", (unsigned long)self.name.length, self.name];
    if (self.qth.length > 0) [s appendFormat:@"<QTH:%lu>%@ ", (unsigned long)self.qth.length, self.qth];
    if (self.notes.length > 0) [s appendFormat:@"<COMMENT:%lu>%@ ", (unsigned long)self.notes.length, self.notes];
    [s appendString:@"<EOR>\n"];
    return s;
}
@end

@interface TX500CWQSOAssistant ()
@property (nonatomic, strong, readwrite) NSMutableArray<TX500CWHeardStation *> *internalHeardStations;
@property (nonatomic, strong, readwrite) NSMutableArray<TX500QSOContact *> *internalLoggedContacts;
@end

@implementation TX500CWQSOAssistant

- (instancetype)init {
    self = [super init];
    if (self) {
        _qsoState = TX500QSOStateIdle;
        _activeTargetCallsign = @"";
        _activeRstSent = @"599";
        _activeRstRcvd = @"599";
        _activeName = @"";
        _activeQTH = @"";
        _myCallsign = @"EP2AES";
        _currentFrequencyHz = 14050000;
        _currentBand = @"20m";
        _internalHeardStations = [NSMutableArray array];
        _internalLoggedContacts = [NSMutableArray array];
    }
    return self;
}

- (NSArray<TX500CWHeardStation *> *)heardStations {
    @synchronized (self.internalHeardStations) {
        return [self.internalHeardStations copy];
    }
}

- (NSArray<TX500QSOContact *> *)loggedContacts {
    @synchronized (self.internalLoggedContacts) {
        return [self.internalLoggedContacts copy];
    }
}

#pragma mark - State Description & Suggestions

- (NSString *)stateDescription {
    switch (self.qsoState) {
        case TX500QSOStateIdle:
            if (self.activeTargetCallsign.length > 0) {
                return [NSString stringWithFormat:@"CQ/TEST heard from %@. Ready to answer.", self.activeTargetCallsign];
            }
            return @"Monitoring frequency. Select an heard CQ to answer or initiate a CQ.";
        case TX500QSOStateCallingCQ:
            return [NSString stringWithFormat:@"Calling CQ as %@ (Run Mode)... Waiting for callers", self.myCallsign];
        case TX500QSOStateAnsweringCQ:
            return [NSString stringWithFormat:@"Answering station %@. Establishing contact.", self.activeTargetCallsign];
        case TX500QSOStateExchangeReport:
            return [NSString stringWithFormat:@"Contact established with %@. Exchanging reports (%@).", self.activeTargetCallsign, self.activeRstSent ?: @"5NN"];
        case TX500QSOStateExchangeInfo:
            return [NSString stringWithFormat:@"Exchanging operator details with %@.", self.activeTargetCallsign];
        case TX500QSOStateSigningOff:
            return [NSString stringWithFormat:@"Signing off with %@ (73 / SK).", self.activeTargetCallsign];
        case TX500QSOStateCompleted:
            return [NSString stringWithFormat:@"QSO with %@ completed. Contact logged.", self.activeTargetCallsign];
    }
}

- (BOOL)hasActionableStep {
    switch (self.qsoState) {
        case TX500QSOStateIdle:
        case TX500QSOStateCallingCQ:
        case TX500QSOStateAnsweringCQ:
        case TX500QSOStateExchangeReport:
        case TX500QSOStateExchangeInfo:
        case TX500QSOStateSigningOff:
        case TX500QSOStateCompleted:
            return YES;
    }
}

- (NSString *)suggestedActionTitle {
    switch (self.qsoState) {
        case TX500QSOStateIdle:
            if (self.activeTargetCallsign.length > 0) {
                return [NSString stringWithFormat:@"▶ Answer %@ (%@ DE %@ K)", self.activeTargetCallsign, self.activeTargetCallsign, self.myCallsign];
            }
            return @"▶ Start Calling CQ (F1)";
        case TX500QSOStateCallingCQ:
            return @"⏹ Stop Calling CQ";
        case TX500QSOStateAnsweringCQ:
            return [NSString stringWithFormat:@"▶ Send Call: %@ DE %@ K", self.activeTargetCallsign, self.myCallsign];
        case TX500QSOStateExchangeReport:
            return [NSString stringWithFormat:@"▶ Send Report: UR %@ BK", self.activeRstSent ?: @"5NN"];
        case TX500QSOStateExchangeInfo:
            return @"▶ Send Info: FB 73 TU EE";
        case TX500QSOStateSigningOff:
            return [NSString stringWithFormat:@"▶ Send 73 & Log: TU 73 DE %@ SK", self.myCallsign];
        case TX500QSOStateCompleted:
            return @"▶ Ready for Next QSO (Call CQ)";
    }
}

- (NSString *)suggestedActionMacro {
    switch (self.qsoState) {
        case TX500QSOStateIdle:
            if (self.activeTargetCallsign.length > 0) {
                return [NSString stringWithFormat:@"%@ DE %@ K", self.activeTargetCallsign, self.myCallsign];
            }
            return [NSString stringWithFormat:@"CQ CQ DE %@ %@ K", self.myCallsign, self.myCallsign];
        case TX500QSOStateCallingCQ:
            return @"";
        case TX500QSOStateAnsweringCQ:
            return [NSString stringWithFormat:@"%@ DE %@ K", self.activeTargetCallsign, self.myCallsign];
        case TX500QSOStateExchangeReport:
            return [NSString stringWithFormat:@"UR %@ BK", self.activeRstSent ?: @"5NN"];
        case TX500QSOStateExchangeInfo:
            return [NSString stringWithFormat:@"NAME %@ QTH %@ 73", self.activeName.length ? self.activeName : @"OP", self.activeQTH.length ? self.activeQTH : @"QTH"];
        case TX500QSOStateSigningOff:
            return [NSString stringWithFormat:@"TU 73 DE %@ SK", self.myCallsign];
        case TX500QSOStateCompleted:
            return [NSString stringWithFormat:@"CQ CQ DE %@ %@ K", self.myCallsign, self.myCallsign];
    }
}

#pragma mark - Stream Ingestion & Pattern Detection

- (void)processDecodedTextStream:(NSString *)stream currentWPM:(double)wpm snrDb:(double)snr {
    if (stream.length == 0) return;

    // 1. Pre-clean: strip non-alphanumeric noise chars (unicode glitches, dashes, hyphens, slashes)
    NSMutableString *clean = [stream mutableCopy];
    NSRegularExpression *noiseRegex = [NSRegularExpression regularExpressionWithPattern:@"[^A-Za-z0-9\\s]" options:0 error:nil];
    [noiseRegex replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@" "];

    // 2. Split glued contest prefixes: TESTHG8W -> TEST HG8W, CQHG8W -> CQ HG8W, DEHG8W -> DE HG8W
    NSRegularExpression *prefixRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(TEST|CQ|DE|UR)([A-Z0-9]{3,8})\\b" options:NSRegularExpressionCaseInsensitive error:nil];
    [prefixRegex replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@"$1 $2"];

    // 3. Split glued signal reports: 5NN101 -> 5NN 101, 599042 -> 599 042
    NSRegularExpression *reportRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(5NN|599|579|589)([0-9]+)\\b" options:NSRegularExpressionCaseInsensitive error:nil];
    [reportRegex replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@"$1 $2"];

    // 4. Split glued signoffs: QSLTU -> QSL TU, QSLAU -> QSL TU
    NSRegularExpression *signoffRegex = [NSRegularExpression regularExpressionWithPattern:@"\\b(QSL)(TU|AU)\\b" options:NSRegularExpressionCaseInsensitive error:nil];
    [signoffRegex replaceMatchesInString:clean options:0 range:NSMakeRange(0, clean.length) withTemplate:@"$1 TU"];

    NSArray *rawTokens = [[clean uppercaseString] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    for (NSString *t in rawTokens) {
        if (t.length > 0) [tokens addObject:t];
    }
    if (tokens.count == 0) return;

    // Look at recent window of tokens (up to 30)
    NSInteger lookback = MIN((NSInteger)tokens.count, (NSInteger)30);
    NSArray<NSString *> *recentWords = [tokens subarrayWithRange:NSMakeRange(tokens.count - lookback, lookback)];

    // 1. Detect Standard and Contest CQs: "CQ [TEST/DX] [DE] <CALL>" or "TEST <CALL> [CALL]"
    for (NSInteger i = 0; i < (NSInteger)recentWords.count; i++) {
        NSString *w = recentWords[i];
        if ([w isEqualToString:@"CQ"] || [w isEqualToString:@"TEST"]) {
            // Check subsequent tokens for callsign
            for (NSInteger j = i + 1; j < MIN((NSInteger)recentWords.count, i + 4); j++) {
                NSString *candidate = recentWords[j];
                if ([candidate isEqualToString:@"DE"] || [candidate isEqualToString:@"TEST"] ||
                    [candidate isEqualToString:@"DX"] || [candidate isEqualToString:@"CQ"] ||
                    [candidate isEqualToString:@"MC"] || [candidate isEqualToString:@"OC"] ||
                    [candidate isEqualToString:@"K"] || [candidate isEqualToString:@"BK"]) {
                    continue;
                }
                if ([self isValidCallsign:candidate] && ![candidate isEqualToString:self.myCallsign.uppercaseString]) {
                    [self recordHeardStation:candidate wpm:wpm snrDb:snr];
                    if (self.qsoState == TX500QSOStateIdle || self.activeTargetCallsign.length == 0) {
                        self.activeTargetCallsign = candidate;
                        [self notifyStateChanged];
                    }
                    break;
                }
            }
        } else if ([self isValidCallsign:w] && ![w isEqualToString:self.myCallsign.uppercaseString]) {
            // Repeated callsign pattern: "<CALL> <CALL>" (e.g. "HG8W HG8W")
            if (i + 1 < (NSInteger)recentWords.count && [recentWords[i + 1] isEqualToString:w]) {
                [self recordHeardStation:w wpm:wpm snrDb:snr];
                if (self.qsoState == TX500QSOStateIdle || self.activeTargetCallsign.length == 0) {
                    self.activeTargetCallsign = w;
                    [self notifyStateChanged];
                }
            }
        }
    }

    // 2. Detect Station Answering our CQ: "<MYCALL> DE <CALL>"
    if (self.qsoState == TX500QSOStateCallingCQ) {
        for (NSInteger i = 0; i < (NSInteger)recentWords.count - 2; i++) {
            if ([recentWords[i] isEqualToString:self.myCallsign.uppercaseString] && [recentWords[i + 1] isEqualToString:@"DE"]) {
                NSString *caller = recentWords[i + 2];
                if ([self isValidCallsign:caller]) {
                    self.activeTargetCallsign = caller;
                    self.qsoState = TX500QSOStateExchangeReport;
                    [self notifyStateChanged];
                    break;
                }
            }
        }
    }

    // 3. Detect RST reports and serial exchanges: "599" or "5NN" + serial
    for (NSInteger i = 0; i < (NSInteger)recentWords.count; i++) {
        NSString *w = recentWords[i];
        if ([w isEqualToString:@"599"] || [w isEqualToString:@"5NN"] || [w hasPrefix:@"579"] || [w hasPrefix:@"589"]) {
            self.activeRstRcvd = [w isEqualToString:@"5NN"] ? @"599" : w;

            // Check if preceded by a valid callsign (e.g. "YE3AJJ 5NN 101")
            if (i > 0) {
                NSString *prev = recentWords[i - 1];
                if ([self isValidCallsign:prev] && ![prev isEqualToString:self.myCallsign.uppercaseString]) {
                    [self recordHeardStation:prev wpm:wpm snrDb:snr];
                    if (self.activeTargetCallsign.length == 0) {
                        self.activeTargetCallsign = prev;
                    }
                }
            }

            // Check if followed by serial exchange (e.g. "101", "042")
            if (i + 1 < (NSInteger)recentWords.count) {
                NSString *nxt = recentWords[i + 1];
                if (nxt.length >= 1 && nxt.length <= 5 && [nxt rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
                    self.activeExchangeRcvd = nxt;
                }
            }

            if (self.qsoState == TX500QSOStateAnsweringCQ) {
                self.qsoState = TX500QSOStateExchangeReport;
                [self notifyStateChanged];
            }
        }

        // 4. Detect Sign-offs: "73", "SK", "EE", "TU", "QSL"
        if ([w isEqualToString:@"73"] || [w isEqualToString:@"SK"] || [w isEqualToString:@"EE"] || [w isEqualToString:@"TU"] || [w isEqualToString:@"QSL"]) {
            if (self.qsoState == TX500QSOStateExchangeReport || self.qsoState == TX500QSOStateExchangeInfo) {
                self.qsoState = TX500QSOStateSigningOff;
                [self notifyStateChanged];
            }
        }
    }
}

- (BOOL)isValidCallsign:(NSString *)token {
    if (token.length < 3 || token.length > 9) return NO;

    // Reject non-callsign procedural words, common RST/contest tokens
    static NSSet<NSString *> *excludedWords = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        excludedWords = [NSSet setWithObjects:
            @"TEST", @"NONE", @"NAME", @"RST", @"RIG", @"ANT", @"QTH", @"QSL",
            @"5NN", @"599", @"579", @"589", @"101", @"73", @"SK", @"BK", @"EE",
            @"TU", @"DX", @"DE", @"CQ", @"OP", @"UR", @"AGN", @"FB", @"GM", @"GA", @"GE", nil
        ];
    });
    if ([excludedWords containsObject:token]) return NO;

    // Must contain at least one letter
    if ([token rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location == NSNotFound) {
        return NO;
    }

    // Must match amateur radio callsign structure: 1-3 prefix alphanumeric, 1 digit, 1-4 suffix alphanumeric
    static NSRegularExpression *regex = nil;
    static dispatch_once_t regexToken;
    dispatch_once(&regexToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^[A-Z0-9]{1,3}[0-9][A-Z0-9]{1,4}$" options:0 error:nil];
    });
    return [regex numberOfMatchesInString:token options:0 range:NSMakeRange(0, token.length)] > 0;
}

- (void)recordHeardStation:(NSString *)call wpm:(double)wpm snrDb:(double)snr {
    @synchronized (self.internalHeardStations) {
        TX500CWHeardStation *found = nil;
        for (TX500CWHeardStation *st in self.internalHeardStations) {
            if ([st.callsign isEqualToString:call]) {
                found = st;
                break;
            }
        }

        if (found) {
            found.wpm = wpm > 0 ? wpm : found.wpm;
            found.snrDb = snr;
            found.frequencyHz = self.currentFrequencyHz;
            found.timestamp = [NSDate date];
            found.count++;
        } else {
            TX500CWHeardStation *st = [TX500CWHeardStation new];
            st.callsign = call;
            st.wpm = wpm > 0 ? wpm : 22.0;
            st.snrDb = snr;
            st.frequencyHz = self.currentFrequencyHz;
            st.timestamp = [NSDate date];
            [self.internalHeardStations insertObject:st atIndex:0];
            if (self.internalHeardStations.count > 25) {
                [self.internalHeardStations removeLastObject];
            }
        }
    }

    if (self.onHeardStationsUpdated) {
        NSArray *snap = [self heardStations];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onHeardStationsUpdated) self.onHeardStationsUpdated(snap);
        });
    }
}

#pragma mark - Workflow Actions

- (void)selectAndAnswerStation:(TX500CWHeardStation *)station {
    self.activeTargetCallsign = station.callsign;
    self.activeRstSent = @"599";
    self.activeRstRcvd = @"599";
    self.qsoState = TX500QSOStateAnsweringCQ;
    [self notifyStateChanged];
}

- (void)startCallingCQ {
    self.activeTargetCallsign = @"";
    self.qsoState = TX500QSOStateCallingCQ;
    [self notifyStateChanged];
}

- (void)advanceQSOStepWithAction:(void (^)(NSString *macroToTransmit))transmitBlock {
    NSString *macro = [self suggestedActionMacro];

    switch (self.qsoState) {
        case TX500QSOStateIdle:
            if (self.activeTargetCallsign.length > 0) {
                self.qsoState = TX500QSOStateAnsweringCQ;
                if (transmitBlock) transmitBlock(macro);
            } else {
                self.qsoState = TX500QSOStateCallingCQ;
                if (transmitBlock) transmitBlock(macro);
            }
            break;
        case TX500QSOStateCallingCQ:
            // Halts Auto-CQ
            self.qsoState = TX500QSOStateIdle;
            break;
        case TX500QSOStateAnsweringCQ:
            self.qsoState = TX500QSOStateExchangeReport;
            if (transmitBlock) transmitBlock(macro);
            break;
        case TX500QSOStateExchangeReport:
            self.qsoState = TX500QSOStateSigningOff;
            if (transmitBlock) transmitBlock(macro);
            break;
        case TX500QSOStateExchangeInfo:
            self.qsoState = TX500QSOStateSigningOff;
            if (transmitBlock) transmitBlock(macro);
            break;
        case TX500QSOStateSigningOff:
            if (transmitBlock) transmitBlock(macro);
            [self logCurrentQSO];
            self.qsoState = TX500QSOStateCompleted;
            break;
        case TX500QSOStateCompleted:
            self.qsoState = TX500QSOStateIdle;
            self.activeTargetCallsign = @"";
            break;
    }

    [self notifyStateChanged];
}

- (void)resetQSOState {
    self.qsoState = TX500QSOStateIdle;
    self.activeTargetCallsign = @"";
    self.activeRstSent = @"599";
    self.activeRstRcvd = @"599";
    [self notifyStateChanged];
}

- (void)notifyStateChanged {
    if (self.onQSOStateChanged) {
        TX500QSOState st = self.qsoState;
        NSString *desc = self.stateDescription;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onQSOStateChanged) self.onQSOStateChanged(st, desc);
        });
    }
}

#pragma mark - ADIF Contact Logging

- (void)logCurrentQSO {
    if (self.activeTargetCallsign.length == 0) return;

    TX500QSOContact *contact = [TX500QSOContact new];
    contact.callsign = self.activeTargetCallsign.uppercaseString;
    contact.mode = @"CW";
    contact.rstSent = self.activeRstSent.length > 0 ? self.activeRstSent : @"599";
    contact.rstRcvd = self.activeRstRcvd.length > 0 ? self.activeRstRcvd : @"599";
    contact.name = self.activeName;
    contact.qth = self.activeQTH;
    contact.frequencyMHz = (double)self.currentFrequencyHz / 1000000.0;
    contact.band = self.currentBand.length > 0 ? self.currentBand : @"20m";

    @synchronized (self.internalLoggedContacts) {
        [self.internalLoggedContacts insertObject:contact atIndex:0];
    }

    // Also persist to central SQLite logbook and trigger zero-click cloud uploads
    [[TX500LogbookManager sharedManager] addContactFromCW:contact
                                                   myCall:self.myCallsign
                                                   myGrid:nil];
    TX500LogRecord *cloudRec = [[TX500LogRecord alloc] init];
    cloudRec.callsign = [contact.callsign uppercaseString];
    cloudRec.band = [contact.band lowercaseString];
    cloudRec.frequencyHz = (uint64_t)(contact.frequencyMHz * 1e6);
    cloudRec.mode = @"CW";
    cloudRec.rstSent = contact.rstSent ?: @"599";
    cloudRec.rstRcvd = contact.rstRcvd ?: @"599";
    cloudRec.name = contact.name;
    cloudRec.qth = contact.qth;
    cloudRec.notes = contact.notes;
    cloudRec.myCall = self.myCallsign ?: @"EP2AES";
    [[TX500CloudSyncEngine sharedEngine] uploadContactImmediately:cloudRec completion:nil];

    if (self.onContactLogged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onContactLogged) self.onContactLogged(contact);
        });
    }
}

- (void)clearLog {
    @synchronized (self.internalLoggedContacts) {
        [self.internalLoggedContacts removeAllObjects];
    }
}

- (NSString *)generateFullADIFString {
    NSMutableString *adif = [NSMutableString string];
    [adif appendString:@"ADIF Export from Lab599 Utility CW Station\n"];
    [adif appendString:@"<ADIF_VER:5>3.1.4\n"];
    [adif appendString:@"<PROGRAMID:14>Lab599 Utility\n"];
    [adif appendString:@"<EOH>\n\n"];

    @synchronized (self.internalLoggedContacts) {
        for (TX500QSOContact *c in self.internalLoggedContacts) {
            [adif appendString:[c adifRecordString]];
        }
    }
    return adif;
}

- (BOOL)exportADIFToFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *adifContent = [self generateFullADIFString];
    return [adifContent writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:error];
}

@end
