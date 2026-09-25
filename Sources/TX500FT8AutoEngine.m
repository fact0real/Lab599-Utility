//
//  TX500FT8AutoEngine.m
//  Lab599 Utility
//
//  Intelligent Autonomous Operating Engine & Full QSO Sequencer for FT8
//

#import "TX500FT8AutoEngine.h"
#import "TX500LogbookManager.h"
#import "TX500CloudSyncEngine.h"

@implementation TX500FT8LoggedQSO
@end

@interface TX500FT8AutoEngine () {
    NSMutableArray<TX500FT8LoggedQSO *> *_internalSessionLog;
    NSMutableSet<NSString *> *_internalWorkedCalls;
    NSMutableSet<NSString *> *_internalWorkedGrids;
    NSInteger _txRetryCount;
    BOOL _qsoStartedByAutoHunter;
    BOOL _resumeCQAfterCurrentQSO;
    BOOL _resumeCQWhenRadioReturnsToRX;
    NSString *_pendingCompletionText;
    NSString *_lastCQText;
    TX500FT8SlotParity _lastCQParity;
    NSInteger _lastCQLimit;
    TX500FT8Message *_pendingCaller;
    NSInteger _pendingCallerParity;
    NSDate *_pendingCallerReceivedAt;
}

@property (nonatomic, assign, readwrite) TX500FT8QSOPhase qsoPhase;
@property (nonatomic, copy, readwrite) NSString *activeDXCall;
@property (nonatomic, copy, readwrite) NSString *activeDXGrid;
@property (nonatomic, copy, readwrite) NSString *sentReport;
@property (nonatomic, copy, readwrite) NSString *rcvdReport;
@property (nonatomic, copy, readwrite) NSString *activeDXCountry;
@property (nonatomic, copy, readwrite) NSString *activeDXFlag;
@property (nonatomic, assign, readwrite) double activeDXDistanceKm;
@property (nonatomic, assign, readwrite) NSInteger autoCQCurrentCount;
@property (nonatomic, copy, readwrite) NSString *autoCQStatus;
@property (nonatomic, copy, readwrite) NSString *autoHunterStatus;
@property (nonatomic, strong, readwrite, nullable) NSArray<TX500FT8Message *> *lastDecodedMessages;
@property (nonatomic, assign, readwrite) NSInteger lastDecodedParity;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *unansweringCalls;
- (void)engageStation:(TX500FT8Message *)target automaticHunter:(BOOL)automaticHunter;
- (void)completeAndLogQSO;
- (void)resumeCQIfSafe;
- (void)rememberWaitingCallerFromMessages:(NSArray<TX500FT8Message *> *)messages
                              excludingCall:(NSString *)excludedCall
                                     parity:(NSInteger)parity;
- (BOOL)engageWaitingCallerIfSafe;

@end

@implementation TX500FT8AutoEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        _qsoPhase = TX500FT8QSOPhaseIdle;
        _internalSessionLog = [NSMutableArray array];
        _internalWorkedCalls = [NSMutableSet set];
        _internalWorkedGrids = [NSMutableSet set];
        _unansweringCalls = [NSMutableDictionary dictionary];

        _autoCQTargetCount = 10;
        _autoCQCurrentCount = 0;
        // A contact that began from CQ resumes that CQ loop after RX recovery.
        // Manual/Hunter contacts remain opt-in through this property.
        _resumeAutoCQAfterQSO = NO;
        _autoCQStatus = @"Auto-CQ: Idle";

        _autoSeqEnabled = YES;
        _callFirstEnabled = YES;

        _autoHunterCriteria = TX500FT8HunterCriteriaMaxDistance;
        _autoHunterMinSNR = -24.0f;
        _autoHunterSkipWorked = YES;
        _autoHunterContinent = @"ALL";
        _autoHunterStatus = @"Auto-Hunter: Monitoring band";

        // Total keyed transmissions before giving up (initial + retries).
        NSInteger savedAttempts = [[NSUserDefaults standardUserDefaults] integerForKey:@"TX500_MaxReplyAttempts"];
        _maxReplyAttempts = (savedAttempts >= 1 && savedAttempts <= 9) ? savedAttempts : 3;
    }
    return self;
}


- (BOOL)isQSOActive {
    return _qsoPhase != TX500FT8QSOPhaseIdle && _qsoPhase != TX500FT8QSOPhaseComplete;
}

- (NSArray<TX500FT8LoggedQSO *> *)sessionLog {
    return [_internalSessionLog copy];
}

- (NSSet<NSString *> *)workedCallsigns {
    return [_internalWorkedCalls copy];
}

- (NSSet<NSString *> *)workedGrids {
    return [_internalWorkedGrids copy];
}

#pragma mark - Auto-CQ & Operating Mode Controls

- (void)setCallingCQState:(BOOL)callingCQ {
    if (callingCQ) {
        self.qsoPhase = TX500FT8QSOPhaseCallingCQ;
        self.activeDXCall = @"";
        self.activeDXGrid = @"";
    } else if (self.qsoPhase == TX500FT8QSOPhaseCallingCQ) {
        self.qsoPhase = TX500FT8QSOPhaseIdle;
    }
    [self notifyStatus];
}

- (void)startAutoCQWithLimit:(NSInteger)count {
    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSString *myGrid = self.audioEngine.myGrid ?: @"KM35";
    NSString *cqMsg = [TX500FT8Message messageForPhase:6 myCall:myCall myGrid:myGrid dxCall:@"" dxGrid:nil myReport:nil rcvdReport:nil];
    [self startCQWithText:cqMsg parity:self.audioEngine.txSlotParity limit:count];
}

- (BOOL)startCQWithText:(NSString *)text parity:(TX500FT8SlotParity)parity limit:(NSInteger)count {
    if (![text.uppercaseString hasPrefix:@"CQ "] || !self.audioEngine) return NO;
    if (!self.audioEngine.isSimulationMode && self.audioEngine.requiresVerifiedCATDial &&
        !self.audioEngine.catDialAndModeVerified) {
        if (self.logHandler) self.logHandler(@"[Auto-CQ] Radio frequency and DIG mode are not CAT-verified; CQ was not armed.");
        return NO;
    }
    if (!self.audioEngine.isMonitoring) {
        NSError *err = nil;
        if (![self.audioEngine startMonitoring:&err]) {
            if (self.logHandler) self.logHandler([NSString stringWithFormat:@"[Auto-CQ] Could not start monitoring: %@", err.localizedDescription ?: @"audio unavailable"]);
            return NO;
        }
    }
    self.autoCQTargetCount = count;
    self.autoCQCurrentCount = 0;
    self.isAutoCQActive = YES;
    self.isAutoHunterActive = NO; // Mutual exclusivity for autonomous transmission

    self.qsoPhase = TX500FT8QSOPhaseCallingCQ;
    self.activeDXCall = @"";
    self.activeDXGrid = @"";

    TX500FT8SlotParity cqParity = parity;
    if (cqParity != TX500FT8SlotParityEven && cqParity != TX500FT8SlotParityOdd) {
        cqParity = TX500FT8SlotParityAuto;
    }
    [self.audioEngine armTransmitWithText:text parity:cqParity];
    self.audioEngine.repeatArmedTransmission = YES;
    _lastCQText = [text copy];
    _lastCQParity = cqParity;
    _lastCQLimit = count;
    _resumeCQWhenRadioReturnsToRX = NO;

    NSString *limitStr = (count > 0) ? [NSString stringWithFormat:@"%ld", (long)count] : @"∞";
    self.autoCQStatus = [NSString stringWithFormat:@"📡 Auto-CQ: Waiting for first TX · limit %@", limitStr];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[Auto-CQ] CQ armed on one slot parity (Limit: %@): '%@'", limitStr, text]);
    }
    [self notifyStatus];
    return YES;
}

- (void)noteTransmittedText:(NSString *)text {
    NSString *normalized = [[text ?: @"" uppercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *completion = [[_pendingCompletionText ?: @"" uppercaseString]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (completion.length > 0 && [normalized isEqualToString:completion] && self.activeDXCall.length > 0) {
        _pendingCompletionText = nil;
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:
                @"[QSO State] Final acknowledgement was actually transmitted to %@; exchange complete.",
                self.activeDXCall]);
        }
        [self completeAndLogQSO];
        return;
    }
    if (!self.isAutoCQActive || self.qsoPhase != TX500FT8QSOPhaseCallingCQ ||
        ![normalized hasPrefix:@"CQ "]) return;
    self.autoCQCurrentCount++;
    NSString *limit = self.autoCQTargetCount > 0 ? [NSString stringWithFormat:@"%ld", (long)self.autoCQTargetCount] : @"∞";
    self.autoCQStatus = [NSString stringWithFormat:@"📡 Auto-CQ: Sent CQ %ld / %@ · listening for a caller", (long)self.autoCQCurrentCount, limit];
    [self notifyStatus];
}

- (void)noteTransmissionEnded {
    if ([self engageWaitingCallerIfSafe]) return;
    [self resumeCQIfSafe];
}

- (void)stopAutoCQ {
    if (!self.isAutoCQActive) return;
    self.isAutoCQActive = NO;
    _resumeCQWhenRadioReturnsToRX = NO;
    _pendingCaller = nil;
    _pendingCallerReceivedAt = nil;
    self.autoCQStatus = @"Auto-CQ: Stopped";
    if (self.qsoPhase == TX500FT8QSOPhaseCallingCQ) {
        self.qsoPhase = TX500FT8QSOPhaseIdle;
        [self.audioEngine disarmTransmit];
    }
    if (self.logHandler) {
        self.logHandler(@"[Auto-CQ] Stopped.");
    }
    [self notifyStatus];
}

#pragma mark - Auto-Hunter Controls

- (void)startAutoHunter {
    self.isAutoHunterActive = YES;
    self.isAutoCQActive = NO;
    self.autoHunterStatus = @"🎯 Auto-Hunter: Scanning band for qualifying CQs...";
    if (self.logHandler) {
        self.logHandler(@"[Auto-Hunter] Activated. Monitoring CQs according to selection criteria.");
    }
    if (!self.audioEngine.isMonitoring) {
        NSError *err = nil;
        [self.audioEngine startMonitoring:&err];
    }
    [self notifyStatus];
    if (self.lastDecodedMessages.count > 0 && !self.isQSOActive) {
        [self evaluateAutoHunterCandidates];
    }
}

- (void)stopAutoHunter {
    BOOL wasActive = self.isAutoHunterActive;
    self.isAutoHunterActive = NO;
    self.autoHunterStatus = @"Auto-Hunter: Inactive";
    if (_qsoStartedByAutoHunter && self.isQSOActive) {
        [self.audioEngine disarmTransmit];
        self.qsoPhase = TX500FT8QSOPhaseIdle;
        self.activeDXCall = @"";
        self.activeDXGrid = @"";
        _qsoStartedByAutoHunter = NO;
    }
    if (self.logHandler && wasActive) {
        self.logHandler(@"[Auto-Hunter] Deactivated.");
    }
    [self notifyStatus];
}

- (void)evaluateAutoHunterCandidates {
    if (!self.isAutoHunterActive || self.isQSOActive || self.lastDecodedMessages.count == 0) return;
    [self runAutoHunterEvaluationWithMessages:self.lastDecodedMessages parity:self.lastDecodedParity];
}

#pragma mark - Station Engagement & QSO Sequencer

- (void)engageCaller:(TX500FT8Message *)caller inReplyToSlotParity:(NSInteger)slotParity {
    if (!caller || caller.callerCall.length == 0) return;
    if (self.isQSOActive && self.activeDXCall.length > 0) {
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:
                @"[QSO Lock] Ignored %@ while the contact with %@ is still in progress.",
                caller.callerCall, self.activeDXCall]);
        }
        return;
    }

    self.activeDXCall = caller.callerCall;
    self.activeDXGrid = caller.grid ?: @"";
    self.activeDXCountry = caller.countryName;
    self.activeDXFlag = caller.countryFlag;
    self.activeDXDistanceKm = caller.distanceKm;
    self.sentReport = [NSString stringWithFormat:@"%+03d", (int)roundf(caller.snrDb)];
    self.rcvdReport = (caller.snrReport.length > 0) ? caller.snrReport : @"-10";
    _txRetryCount = 0;
    _qsoStartedByAutoHunter = NO;

    // Align audio frequencies
    if (caller.freqHz > 200.0f && caller.freqHz < 2900.0f) {
        self.audioEngine.rxAudioFrequencyHz = caller.freqHz;
        if (self.audioEngine.lockTxRxFrequencies) {
            self.audioEngine.txAudioFrequencyHz = caller.freqHz;
        }
    }

    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSString *myGrid = self.audioEngine.myGrid ?: @"KM35";

    NSInteger phaseToTransmit = 2; // Tx 2: DXCall MyCall Report (standard reply to CQ response)
    if (caller.messageType == TX500FT8MessageTypeReport || caller.messageType == TX500FT8MessageTypeRogerReport) {
        // Caller skipped grid and sent report directly
        phaseToTransmit = 3; // Tx 3: DXCall MyCall R+Report
        self.qsoPhase = TX500FT8QSOPhaseSendingRogerRpt;
    } else {
        self.qsoPhase = TX500FT8QSOPhaseSendingReport;
    }

    NSString *replyMsg = [TX500FT8Message messageForPhase:phaseToTransmit
                                                   myCall:myCall
                                                   myGrid:myGrid
                                                   dxCall:self.activeDXCall
                                                   dxGrid:self.activeDXGrid
                                                 myReport:self.sentReport
                                               rcvdReport:self.rcvdReport];

    // Answer on the alternate slot parity to the received message
    TX500FT8SlotParity nextParity = (slotParity == 0) ? TX500FT8SlotParityOdd : TX500FT8SlotParityEven;
    [self.audioEngine armTransmitWithText:replyMsg parity:nextParity];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[Auto-Seq] Answered by %@ (%@, %.0f km, SNR %@ dB). Replying with Tx %ld: '%@'",
                         self.activeDXCall, self.activeDXCountry, self.activeDXDistanceKm, self.sentReport, (long)phaseToTransmit, replyMsg]);
    }

    if (self.onDXStationEngaged) {
        self.onDXStationEngaged(self.activeDXCall, self.activeDXGrid, self.sentReport, self.qsoPhase);
    }

    [self notifyStatus];
}

- (void)engageStation:(TX500FT8Message *)target {
    [self engageStation:target automaticHunter:NO];
}

- (void)engageStation:(TX500FT8Message *)target automaticHunter:(BOOL)automaticHunter {
    if (!target || target.callerCall.length == 0) return;
    // One radio can own exactly one FT8 exchange at a time.  All entry points
    // (Auto-CQ, Auto-Hunter, table double-click and keyboard shortcuts) pass
    // through this gate so none can overwrite the active DX call or frequency.
    if (self.isQSOActive && self.activeDXCall.length > 0) {
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:
                @"[QSO Lock] Cannot engage %@ until the contact with %@ completes, times out or is aborted.",
                target.callerCall, self.activeDXCall]);
        }
        return;
    }

    // If message was directed to us, engage as response to our CQ/callsign
    if (target.isDirectedToMe) {
        [self engageCaller:target inReplyToSlotParity:target.slotParity];
        return;
    }

    self.activeDXCall = target.callerCall;
    self.activeDXGrid = target.grid ?: @"";
    self.activeDXCountry = target.countryName;
    self.activeDXFlag = target.countryFlag;
    self.activeDXDistanceKm = target.distanceKm;
    self.sentReport = [NSString stringWithFormat:@"%+03d", (int)roundf(target.snrDb)];
    self.rcvdReport = @"-10"; // Default until received
    _txRetryCount = 0;
    _qsoStartedByAutoHunter = automaticHunter;
    _resumeCQAfterCurrentQSO = NO;
    _pendingCompletionText = nil;

    // Align audio frequencies
    if (target.freqHz > 200.0f && target.freqHz < 2900.0f) {
        self.audioEngine.rxAudioFrequencyHz = target.freqHz;
        if (self.audioEngine.lockTxRxFrequencies) {
            self.audioEngine.txAudioFrequencyHz = target.freqHz;
        }
    }

    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSString *myGrid = self.audioEngine.myGrid ?: @"KM35";

    // Build Tx 1: HisCall MyCall Grid (Answer CQ)
    NSString *replyMsg = [TX500FT8Message messageForPhase:1
                                                   myCall:myCall
                                                   myGrid:myGrid
                                                   dxCall:self.activeDXCall
                                                   dxGrid:self.activeDXGrid
                                                 myReport:self.sentReport
                                               rcvdReport:self.rcvdReport];

    self.qsoPhase = TX500FT8QSOPhaseAnsweringCQ;

    // Answer on the alternate slot parity
    TX500FT8SlotParity nextParity = (target.slotParity == 0) ?
                                     TX500FT8SlotParityOdd : TX500FT8SlotParityEven;

    [self.audioEngine armTransmitWithText:replyMsg parity:nextParity];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[QSO State] Engaged %@ (%@, %.0f km). Tx 1: '%@'",
                         self.activeDXCall, self.activeDXCountry, self.activeDXDistanceKm, replyMsg]);
    }

    if (self.onDXStationEngaged) {
        self.onDXStationEngaged(self.activeDXCall, self.activeDXGrid, self.sentReport, self.qsoPhase);
    }

    [self notifyStatus];
}

- (void)abortQSO {
    self.qsoPhase = TX500FT8QSOPhaseIdle;
    self.activeDXCall = @"";
    self.activeDXGrid = @"";
    _qsoStartedByAutoHunter = NO;
    _resumeCQAfterCurrentQSO = NO;
    _resumeCQWhenRadioReturnsToRX = NO;
    _pendingCompletionText = nil;
    _pendingCaller = nil;
    _pendingCallerReceivedAt = nil;
    self.autoCQStatus = @"Auto-CQ: Idle";
    [self.audioEngine disarmTransmit];

    if (self.logHandler) {
        self.logHandler(@"[QSO State] Aborted by operator.");
    }
    [self notifyStatus];
}

- (void)advanceToNextQSOStep {
    if (!self.isQSOActive || self.activeDXCall.length == 0) return;

    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSString *myGrid = self.audioEngine.myGrid ?: @"KM35";
    NSInteger nextPhase = 1;
    NSString *nextMsg = @"";

    switch (self.qsoPhase) {
        case TX500FT8QSOPhaseCallingCQ:
        case TX500FT8QSOPhaseAnsweringCQ:
            nextPhase = 2;
            self.qsoPhase = TX500FT8QSOPhaseSendingReport;
            break;
        case TX500FT8QSOPhaseSendingReport:
            nextPhase = 3;
            self.qsoPhase = TX500FT8QSOPhaseSendingRogerRpt;
            break;
        case TX500FT8QSOPhaseSendingRogerRpt:
            nextPhase = 4;
            self.qsoPhase = TX500FT8QSOPhaseSendingRR73;
            break;
        case TX500FT8QSOPhaseSendingRR73:
            nextPhase = 5;
            self.qsoPhase = TX500FT8QSOPhaseSending73;
            break;
        case TX500FT8QSOPhaseSending73:
            [self completeAndLogQSO];
            return;
        default:
            return;
    }

    nextMsg = [TX500FT8Message messageForPhase:nextPhase
                                        myCall:myCall
                                        myGrid:myGrid
                                        dxCall:self.activeDXCall
                                        dxGrid:self.activeDXGrid
                                      myReport:self.sentReport
                                    rcvdReport:self.rcvdReport];

    TX500FT8SlotParity nextParity = (self.audioEngine.currentSlotParity == 0) ?
                                     TX500FT8SlotParityOdd : TX500FT8SlotParityEven;
    [self.audioEngine armTransmitWithText:nextMsg parity:nextParity];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[QSO State] Advanced to Step %ld: '%@'", (long)nextPhase, nextMsg]);
    }
    [self notifyStatus];
}

#pragma mark - Process Decoded Slot (Intelligence Engine)

- (void)processDecodedSlot:(NSArray<TX500FT8Message *> *)messages parity:(NSInteger)parity {
    for (TX500FT8Message *m in messages) {
        m.slotParity = parity;
    }
    self.lastDecodedMessages = [messages copy];
    self.lastDecodedParity = parity;

    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSString *myGrid = self.audioEngine.myGrid ?: @"KM35";
    TX500FT8SlotParity nextParity = (parity == 0) ? TX500FT8SlotParityOdd : TX500FT8SlotParityEven;

    // 1. Check if we have an active QSO in progress with a specific DX station
    if (self.isQSOActive && self.activeDXCall.length > 0) {
        // A second station can answer our CQ while we are finishing the first
        // contact.  Preserve that directed call instead of losing it when the
        // current RR73/73 completes and the CQ loop resumes.
        if (_resumeCQAfterCurrentQSO && self.callFirstEnabled) {
            [self rememberWaitingCallerFromMessages:messages
                                       excludingCall:self.activeDXCall
                                              parity:parity];
        }
        TX500FT8Message *dxMsg = nil;
        TX500FT8Message *collisionMsg = nil;
        for (TX500FT8Message *m in messages) {
            if ([m.callerCall isEqualToString:self.activeDXCall]) {
                if (m.isDirectedToMe || [m.rawText containsString:myCall]) {
                    dxMsg = m;
                    break;
                } else {
                    collisionMsg = m;
                }
            }
        }

        // Handle Collision: target station answered someone else!
        if (collisionMsg && !dxMsg) {
            NSString *otherCall = collisionMsg.targetCall ?: @"another station";
            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[Auto-Hunter] DX %@ answered %@. Releasing frequency to prevent QRM.", self.activeDXCall, otherCall]);
            }
            // Blacklist station temporarily (180s)
            self.unansweringCalls[self.activeDXCall] = [NSDate dateWithTimeIntervalSinceNow:180.0];
            [self.audioEngine disarmTransmit];
            self.qsoPhase = TX500FT8QSOPhaseIdle;
            self.activeDXCall = @"";
            self.activeDXGrid = @"";
            [self notifyStatus];

            if (self.isAutoHunterActive) {
                // Immediately evaluate remaining qualifying CQs from this slot
                [self runAutoHunterEvaluationWithMessages:messages parity:parity];
            }
            return;
        }

        if (dxMsg) {
            _txRetryCount = 0;
            // Target station replied to us!
            if (dxMsg.snrReport.length > 0) {
                self.rcvdReport = dxMsg.snrReport;
            }
            if (dxMsg.grid.length >= 4 && self.activeDXGrid.length == 0) {
                self.activeDXGrid = dxMsg.grid;
            }

            if (dxMsg.messageType == TX500FT8MessageTypeRR73 || dxMsg.messageType == TX500FT8MessageTypeRRR) {
                // They confirmed our report. Send one courtesy 73 and log only
                // when that final frame actually reaches the transmitter.
                NSString *tx5 = [TX500FT8Message messageForPhase:5 myCall:myCall myGrid:myGrid dxCall:self.activeDXCall dxGrid:self.activeDXGrid myReport:self.sentReport rcvdReport:self.rcvdReport];
                [self.audioEngine armTransmitWithText:tx5 parity:nextParity];
                _pendingCompletionText = [tx5 copy];

                self.qsoPhase = TX500FT8QSOPhaseSending73;
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO State] Received RR73/RRR from %@. Sending Tx 5 (73): '%@'", self.activeDXCall, tx5]);
                }
                [self notifyStatus];
                return;
            } else if (dxMsg.messageType == TX500FT8MessageType73) {
                // Final 73 received. Complete and log contact!
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO State] Received 73 from %@. Contact complete!", self.activeDXCall]);
                }
                [self completeAndLogQSO];
                return;
            } else if (dxMsg.messageType == TX500FT8MessageTypeRogerReport) {
                // They received our report and sent their roger report (R+Report). Send RR73 (Tx 4)!
                NSString *tx4 = [TX500FT8Message messageForPhase:4 myCall:myCall myGrid:myGrid dxCall:self.activeDXCall dxGrid:self.activeDXGrid myReport:self.sentReport rcvdReport:self.rcvdReport];
                [self.audioEngine armTransmitWithText:tx4 parity:nextParity];
                // In the standard FT8 exchange, transmitting RR73 acknowledges
                // the received report and completes both report acknowledgements.
                _pendingCompletionText = [tx4 copy];

                self.qsoPhase = TX500FT8QSOPhaseSendingRR73;
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO State] Roger report received (%@ dB). Sending RR73: '%@'", self.rcvdReport, tx4]);
                }
                [self notifyStatus];
                return;
            } else if (dxMsg.messageType == TX500FT8MessageTypeReport) {
                // A plain report does not acknowledge ours. Always answer with
                // Roger + Report; RR73 is valid only after an R-report.
                NSInteger nextStep = 3;
                NSString *msg = [TX500FT8Message messageForPhase:nextStep myCall:myCall myGrid:myGrid dxCall:self.activeDXCall dxGrid:self.activeDXGrid myReport:self.sentReport rcvdReport:self.rcvdReport];
                [self.audioEngine armTransmitWithText:msg parity:nextParity];

                self.qsoPhase = TX500FT8QSOPhaseSendingRogerRpt;
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO State] Report received (%@ dB). Sending Tx %ld: '%@'", self.rcvdReport, (long)nextStep, msg]);
                }
                [self notifyStatus];
                return;
            } else if (dxMsg.messageType == TX500FT8MessageTypeReplyGrid) {
                // Caller repeated grid (missed our Tx 2). Repeat Tx 2 report!
                NSString *tx2 = [TX500FT8Message messageForPhase:2 myCall:myCall myGrid:myGrid dxCall:self.activeDXCall dxGrid:self.activeDXGrid myReport:self.sentReport rcvdReport:self.rcvdReport];
                [self.audioEngine armTransmitWithText:tx2 parity:nextParity];

                self.qsoPhase = TX500FT8QSOPhaseSendingReport;
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO State] DX repeated grid (%@). Resending Tx 2: '%@'", dxMsg.grid ?: @"", tx2]);
                }
                [self notifyStatus];
                return;
            }
        } else {
            // Did not hear DX station this slot
            _txRetryCount++;
            if (_txRetryCount < self.maxReplyAttempts) {
                NSInteger phaseStep = 0;
                switch (self.qsoPhase) {
                    case TX500FT8QSOPhaseAnsweringCQ: phaseStep = 1; break;
                    case TX500FT8QSOPhaseSendingReport: phaseStep = 2; break;
                    case TX500FT8QSOPhaseSendingRogerRpt: phaseStep = 3; break;
                    case TX500FT8QSOPhaseSendingRR73: phaseStep = 4; break;
                    case TX500FT8QSOPhaseSending73: phaseStep = 5; break;
                    default: break;
                }
                if (phaseStep >= 1 && phaseStep <= 5) {
                    NSString *retryMsg = [TX500FT8Message messageForPhase:phaseStep myCall:myCall myGrid:myGrid dxCall:self.activeDXCall dxGrid:self.activeDXGrid myReport:self.sentReport rcvdReport:self.rcvdReport];
                    [self.audioEngine armTransmitWithText:retryMsg parity:nextParity];
                }
                if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[QSO] No reply from %@; scheduling transmission %ld/%ld.",
                                     self.activeDXCall, (long)(_txRetryCount + 1), (long)self.maxReplyAttempts]);
                }
            } else {
                // Exceeded retry limit — protect radio duty cycle, abort and return to hunt
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"[QSO] ⚠️ Timeout: No response from %@ after %ld transmission(s). Returning to CQ.",
                                     self.activeDXCall, (long)self.maxReplyAttempts]);
                }
                self.unansweringCalls[self.activeDXCall] = [NSDate dateWithTimeIntervalSinceNow:300.0];
                [self.audioEngine disarmTransmit];
                self.qsoPhase = TX500FT8QSOPhaseIdle;
                self.activeDXCall = @"";
                self.activeDXGrid = @"";
                _pendingCompletionText = nil;
                [self notifyStatus];

                if (self.isAutoHunterActive) {
                    // Hunt for another candidate from this slot
                    [self runAutoHunterEvaluationWithMessages:messages parity:parity];
                } else if (_resumeCQAfterCurrentQSO) {
                    _resumeCQWhenRadioReturnsToRX = YES;
                    [self resumeCQIfSafe];
                }
            }
        }
        return;

    }

    // 2. Check for Incoming Callers Answering OUR CQ or Calling Us
    BOOL isCallingCQ = self.isAutoCQActive ||
                       (self.qsoPhase == TX500FT8QSOPhaseCallingCQ) ||
                       (self.audioEngine.isTransmitArmed && [self.audioEngine.queuedTxMessage hasPrefix:@"CQ"]);
    // Auto sequencing advances an explicitly started QSO. It must never turn
    // an unsolicited decode into a new transmission while Auto-Hunter is off.
    BOOL shouldCheckCallers = isCallingCQ;

    if (shouldCheckCallers) {
        NSMutableArray<TX500FT8Message *> *callers = [NSMutableArray array];
        for (TX500FT8Message *m in messages) {
            if (m.isDirectedToMe && m.callerCall.length > 0 && ![m.callerCall isEqualToString:myCall]) {
                [callers addObject:m];
            }
        }

        if (callers.count > 0 && self.callFirstEnabled) {
            // Best caller selection (highest SNR)
            TX500FT8Message *bestCaller = callers[0];
            for (TX500FT8Message *c in callers) {
                if (c.snrDb > bestCaller.snrDb) bestCaller = c;
            }

            _resumeCQAfterCurrentQSO = self.isAutoCQActive || self.qsoPhase == TX500FT8QSOPhaseCallingCQ;
            if (self.isAutoCQActive) {
                self.isAutoCQActive = NO;
                self.autoCQStatus = [NSString stringWithFormat:@"📡 Auto-CQ: Answered by %@ (%+d dB)! Engaging...", bestCaller.callerCall, (int)bestCaller.snrDb];
            }

            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[Auto-Seq] Answered by %@ (%@, %+d dB)! Engaging contact with Tx 2.",
                                 bestCaller.callerCall, bestCaller.grid ?: @"", (int)bestCaller.snrDb]);
            }

            [self engageCaller:bestCaller inReplyToSlotParity:parity];
            return;
        } else if (self.isAutoCQActive) {
            // CQ remains armed on its original parity. Counting only actual
            // keyed transmissions avoids skipped/decode-empty slot drift.
            if (self.autoCQTargetCount > 0 && self.autoCQCurrentCount >= self.autoCQTargetCount) {
                [self stopAutoCQ];
                self.autoCQStatus = [NSString stringWithFormat:@"📡 Auto-CQ: Reached target count of %ld. Listening.", (long)self.autoCQTargetCount];
                return;
            }

            if (!self.audioEngine.isTransmitArmed && !self.audioEngine.isTransmitting) {
                [self stopAutoCQ];
                self.autoCQStatus = @"Auto-CQ paused: transmitter was disarmed; check the diagnostic log.";
                [self notifyStatus];
            }
            return;
        }
    }

    // 3. Algorithm 2: Auto-Hunter Handler
    if (self.isAutoHunterActive && !self.isQSOActive) {
        [self runAutoHunterEvaluationWithMessages:messages parity:parity];
    }
}

- (void)runAutoHunterEvaluationWithMessages:(NSArray<TX500FT8Message *> *)messages parity:(NSInteger)parity {
    (void)parity;
    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    NSMutableArray<TX500FT8Message *> *qualifyingCQs = [NSMutableArray array];

    for (TX500FT8Message *m in messages) {
        if (!m.isCQ || m.callerCall.length == 0 || [m.callerCall isEqualToString:myCall]) continue;
        if (m.snrDb < self.autoHunterMinSNR) continue;
        if (self.autoHunterSkipWorked && [_internalWorkedCalls containsObject:m.callerCall]) continue;

        // Skip unanswering / collision blacklisted stations
        NSDate *blacklistUntil = self.unansweringCalls[m.callerCall];
        if (blacklistUntil && [blacklistUntil timeIntervalSinceNow] > 0) {
            continue;
        }

        // Continent filter
        if (self.autoHunterContinent.length > 0 && ![self.autoHunterContinent isEqualToString:@"ALL"]) {
            if (m.continent.length > 0 && ![m.continent isEqualToString:self.autoHunterContinent]) {
                continue;
            }
        }

        [qualifyingCQs addObject:m];
    }

    if (qualifyingCQs.count == 0) {
        self.autoHunterStatus = @"🎯 Auto-Hunter: Scanning slot... No new qualifying CQs";
        [self notifyStatus];
        return;
    }

    // Rank candidates according to hunter criteria
    TX500FT8Message *target = nil;
    switch (self.autoHunterCriteria) {
        case TX500FT8HunterCriteriaMaxDistance: {
            target = qualifyingCQs[0];
            for (TX500FT8Message *c in qualifyingCQs) {
                if (c.distanceKm > target.distanceKm) target = c;
            }
            break;
        }
        case TX500FT8HunterCriteriaMaxSNR: {
            target = qualifyingCQs[0];
            for (TX500FT8Message *c in qualifyingCQs) {
                if (c.snrDb > target.snrDb) target = c;
            }
            break;
        }
        case TX500FT8HunterCriteriaWeakSignal: {
            target = qualifyingCQs[0];
            for (TX500FT8Message *c in qualifyingCQs) {
                if (c.snrDb < target.snrDb) target = c;
            }
            break;
        }
        case TX500FT8HunterCriteriaNewGrid: {
            for (TX500FT8Message *c in qualifyingCQs) {
                if (c.grid.length >= 4 && ![_internalWorkedGrids containsObject:c.grid]) {
                    target = c;
                    break;
                }
            }
            if (!target) target = qualifyingCQs[0];
            break;
        }
        case TX500FT8HunterCriteriaFirstInSlot:
        default:
            target = qualifyingCQs[0];
            break;
    }

    self.autoHunterStatus = [NSString stringWithFormat:@"🎯 Auto-Hunter: Locked onto %@ (%@, %.0f km, %+d dB) · Answering!",
                             target.callerCall, target.countryName, target.distanceKm, (int)target.snrDb];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[Auto-Hunter] Priority target selected: %@ (%@, %.0f km, SNR %+d dB). Initiating contact!",
                         target.callerCall, target.countryName, target.distanceKm, (int)target.snrDb]);
    }

    [self engageStation:target automaticHunter:YES];
}

#pragma mark - QSO Completion & Logging

- (void)completeAndLogQSO {
    if (self.activeDXCall.length == 0) return;

    TX500FT8LoggedQSO *qso = [[TX500FT8LoggedQSO alloc] init];
    qso.callsign = self.activeDXCall;
    qso.freqHz = self.audioEngine.dialFrequencyHz;
    qso.band = [TX500LogRecord bandForFrequencyHz:qso.freqHz];
    qso.rstSent = self.sentReport;
    qso.rstRcvd = self.rcvdReport;
    qso.grid = self.activeDXGrid;
    qso.countryName = self.activeDXCountry;
    qso.countryFlag = self.activeDXFlag;
    qso.distanceKm = self.activeDXDistanceKm;
    qso.timestamp = [NSDate date];
    qso.mode = (self.audioEngine.protocol == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";

    [_internalSessionLog insertObject:qso atIndex:0];
    [_internalWorkedCalls addObject:qso.callsign];
    if (qso.grid.length >= 4) {
        [_internalWorkedGrids addObject:qso.grid];
    }

    self.qsoPhase = TX500FT8QSOPhaseComplete;
    _qsoStartedByAutoHunter = NO;
    self.activeDXCall = @"";
    self.activeDXGrid = @"";
    _pendingCompletionText = nil;

    id autoLogValue = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_AutoLogQSO"];
    BOOL autoLogEnabled = (autoLogValue == nil || [autoLogValue boolValue]);
    if (autoLogEnabled) [self logCompletedQSOToADIF:qso];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[QSO LOGGED] ★ Contact with %@ successfully completed and logged to session & ADIF logbook!", qso.callsign]);
    }

    if (self.onQSOLogged) {
        self.onQSOLogged(qso);
    }
    [self notifyStatus];

    if (_resumeCQAfterCurrentQSO || self.resumeAutoCQAfterQSO) {
        _resumeCQWhenRadioReturnsToRX = YES;
        [self resumeCQIfSafe];
    }
}

- (void)resumeCQIfSafe {
    if (!_resumeCQWhenRadioReturnsToRX || self.isAutoHunterActive ||
        self.audioEngine.isTransmitting || self.audioEngine.isReceiveRecoveryPending) return;
    if ([self engageWaitingCallerIfSafe]) return;
    _resumeCQWhenRadioReturnsToRX = NO;
    _resumeCQAfterCurrentQSO = NO;
    NSString *text = _lastCQText.length > 0 ? _lastCQText :
        [TX500FT8Message messageForPhase:6
                                  myCall:self.audioEngine.myCallsign ?: @"EP2AES"
                                  myGrid:self.audioEngine.myGrid ?: @"KM35"
                                  dxCall:@"" dxGrid:nil myReport:nil rcvdReport:nil];
    BOOL resumed = [self startCQWithText:text parity:_lastCQParity limit:_lastCQLimit];
    if (!resumed) {
        self.autoCQStatus = @"Auto-CQ paused: unable to arm the next CQ.";
        [self notifyStatus];
    }
    if (self.logHandler) self.logHandler(@"[Auto-CQ] QSO cycle finished; CQ loop resumed from the first call.");
}

- (void)rememberWaitingCallerFromMessages:(NSArray<TX500FT8Message *> *)messages
                              excludingCall:(NSString *)excludedCall
                                     parity:(NSInteger)parity {
    TX500FT8Message *best = nil;
    NSString *myCall = self.audioEngine.myCallsign ?: @"EP2AES";
    for (TX500FT8Message *message in messages) {
        if (!message.isDirectedToMe || message.callerCall.length == 0 ||
            [message.callerCall isEqualToString:myCall] ||
            [message.callerCall isEqualToString:excludedCall]) continue;
        if (!best || message.snrDb > best.snrDb) best = message;
    }
    if (!best) return;

    // Keep the first waiting station for fairness, but refresh a repeated call
    // from that same station with its newest report/grid and signal level.
    if (_pendingCaller && ![_pendingCaller.callerCall isEqualToString:best.callerCall]) return;
    _pendingCaller = [best copy];
    _pendingCallerParity = parity;
    _pendingCallerReceivedAt = [NSDate date];
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:
            @"[Auto-CQ] %@ also called us; queued ahead of the next CQ.", best.callerCall]);
    }
}

- (BOOL)engageWaitingCallerIfSafe {
    if (!_pendingCaller || self.audioEngine.isTransmitting ||
        self.audioEngine.isReceiveRecoveryPending || self.isAutoHunterActive) return NO;
    if (!_pendingCallerReceivedAt || -[_pendingCallerReceivedAt timeIntervalSinceNow] > 45.0) {
        if (self.logHandler) self.logHandler(@"[Auto-CQ] A queued caller expired before a safe reply slot; resuming CQ.");
        _pendingCaller = nil;
        _pendingCallerReceivedAt = nil;
        return NO;
    }

    TX500FT8Message *caller = _pendingCaller;
    NSInteger parity = _pendingCallerParity;
    _pendingCaller = nil;
    _pendingCallerReceivedAt = nil;
    _resumeCQWhenRadioReturnsToRX = NO;
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:
            @"[Auto-CQ] Answering queued caller %@ before sending another CQ.", caller.callerCall]);
    }
    [self engageCaller:caller inReplyToSlotParity:parity];
    return YES;
}

- (void)notifyStatus {
    if (self.onQSOStateChanged) {
        NSString *phaseDesc = @"Idle";
        switch (self.qsoPhase) {
            case TX500FT8QSOPhaseCallingCQ: phaseDesc = @"Calling CQ"; break;
            case TX500FT8QSOPhaseAnsweringCQ: phaseDesc = @"Answering CQ"; break;
            case TX500FT8QSOPhaseSendingReport: phaseDesc = @"Sending Report"; break;
            case TX500FT8QSOPhaseSendingRogerRpt: phaseDesc = @"Sending R+Report"; break;
            case TX500FT8QSOPhaseSendingRR73: phaseDesc = @"Sending RR73"; break;
            case TX500FT8QSOPhaseSending73: phaseDesc = @"Sending 73"; break;
            case TX500FT8QSOPhaseComplete: phaseDesc = @"QSO Complete"; break;
            default: break;
        }
        if (self.isQSOActive && self.activeDXCall.length > 0) {
            self.autoCQStatus = [NSString stringWithFormat:@"🔒 QSO locked: %@ · %@",
                                 self.activeDXCall, phaseDesc];
        }
        self.onQSOStateChanged(self.qsoPhase, phaseDesc);
    }

    if (self.onAlgorithmStatusUpdated) {
        self.onAlgorithmStatusUpdated(self.autoCQStatus, self.autoHunterStatus);
    }
}

#pragma mark - ADIF Logbook & Export

+ (NSString *)qsoLogbookADIFPath {
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *testRoot = environment[@"TX500_TEST_ROOT"];
    NSString *dir = nil;
    if (environment[@"TX500_TEST_MODE"].boolValue && testRoot.length > 0) {
        dir = [testRoot stringByAppendingPathComponent:@"FT8"];
    } else {
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        dir = [appSupport stringByAppendingPathComponent:@"Lab599 Utility/FT8"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"TX500_FT8_Logbook.adi"];
}

- (void)logCompletedQSOToADIF:(TX500FT8LoggedQSO *)qso {
    if (!qso || qso.callsign.length == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *filePath = [TX500FT8AutoEngine qsoLogbookADIFPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSString *header = @"FT8 QSO Logbook - Lab599 Utility for Discovery TX-500\n<ADIF_VER:5>3.1.4\n<PROGRAMID:14>Lab599 Utility\n<EOH>\n\n";
            [header writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }

        NSString *rec = [TX500FT8Message adifRecordForCall:qso.callsign
                                                      band:qso.band
                                                    freqHz:qso.freqHz
                                                   rstSent:qso.rstSent
                                                   rstRcvd:qso.rstRcvd
                                                      grid:qso.grid
                                                      date:qso.timestamp
                                                      mode:qso.mode];

        NSData *data = [rec dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        }

        // Also persist to central SQLite logbook and trigger zero-click cloud uploads
        [[TX500LogbookManager sharedManager] addContactFromFT8:qso
                                                        myCall:self.audioEngine.myCallsign
                                                        myGrid:self.audioEngine.myGrid];
        TX500LogRecord *cloudRec = [[TX500LogRecord alloc] init];
        cloudRec.callsign = [qso.callsign uppercaseString];
        cloudRec.band = [qso.band lowercaseString];
        cloudRec.frequencyHz = qso.freqHz;
        cloudRec.mode = qso.mode ?: @"FT8";
        cloudRec.rstSent = qso.rstSent ?: @"-10";
        cloudRec.rstRcvd = qso.rstRcvd ?: @"-10";
        cloudRec.grid = qso.grid;
        cloudRec.country = qso.countryName;
        cloudRec.myCall = self.audioEngine.myCallsign ?: @"EP2AES";
        cloudRec.myGrid = self.audioEngine.myGrid;
        [[TX500CloudSyncEngine sharedEngine] uploadContactImmediately:cloudRec completion:nil];
    });
}

- (NSString *)generateADIFExport {
    NSMutableString *adif = [NSMutableString string];
    [adif appendString:@"Lab599 Utility FT8 ADIF Export\n"];
    [adif appendString:@"<ADIF_VER:5>3.1.4\n"];
    [adif appendString:@"<PROGRAMID:14>Lab599 Utility\n"];
    [adif appendString:@"<EOH>\n\n"];

    for (TX500FT8LoggedQSO *q in _internalSessionLog) {
        NSString *rec = [TX500FT8Message adifRecordForCall:q.callsign
                                                      band:q.band
                                                    freqHz:q.freqHz
                                                   rstSent:q.rstSent
                                                   rstRcvd:q.rstRcvd
                                                      grid:q.grid
                                                      date:q.timestamp
                                                      mode:q.mode];
        [adif appendString:rec];
    }
    return adif;
}

- (void)clearSessionLog {
    [_internalSessionLog removeAllObjects];
    [_internalWorkedCalls removeAllObjects];
    [_internalWorkedGrids removeAllObjects];
}

@end
