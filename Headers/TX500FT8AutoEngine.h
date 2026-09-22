//
//  TX500FT8AutoEngine.h
//  Lab599 Utility
//
//  Intelligent Autonomous Operating Engine & Full QSO Sequencer for FT8
//  Features Auto-CQ loop with configurable limits, Auto-Hunter multi-criteria DX ranking,
//  6-step QSO progression state machine, and ADIF contact logging.
//

#import <Foundation/Foundation.h>
#import "TX500FT8Message.h"
#import "TX500FT8AudioEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500FT8QSOPhase) {
    TX500FT8QSOPhaseIdle = 0,
    TX500FT8QSOPhaseCallingCQ,       // Tx 6: CQ MyCall MyGrid
    TX500FT8QSOPhaseAnsweringCQ,     // Tx 1: DXCall MyCall MyGrid
    TX500FT8QSOPhaseSendingReport,   // Tx 2: DXCall MyCall +00
    TX500FT8QSOPhaseSendingRogerRpt, // Tx 3: DXCall MyCall R+00
    TX500FT8QSOPhaseSendingRR73,     // Tx 4: DXCall MyCall RR73
    TX500FT8QSOPhaseSending73,       // Tx 5: DXCall MyCall 73
    TX500FT8QSOPhaseComplete         // Finished & Logged
};

typedef NS_ENUM(NSInteger, TX500FT8HunterCriteria) {
    TX500FT8HunterCriteriaMaxDistance = 0, // Furthest distance (Great Circle km)
    TX500FT8HunterCriteriaMaxSNR      = 1, // Strongest signal (highest dB)
    TX500FT8HunterCriteriaWeakSignal  = 2, // Challenging weak DX (lowest dB)
    TX500FT8HunterCriteriaNewGrid     = 3, // Prioritize unworked Maidenhead grids
    TX500FT8HunterCriteriaFirstInSlot = 4  // First valid CQ received
};

@interface TX500FT8LoggedQSO : NSObject
@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, copy) NSString *band;
@property (nonatomic, assign) uint64_t freqHz;
@property (nonatomic, copy) NSString *rstSent;
@property (nonatomic, copy) NSString *rstRcvd;
@property (nonatomic, copy, nullable) NSString *grid;
@property (nonatomic, copy) NSString *countryName;
@property (nonatomic, copy) NSString *countryFlag;
@property (nonatomic, assign) double distanceKm;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, copy) NSString *mode; // @"FT8" or @"FT4"
@end

@interface TX500FT8AutoEngine : NSObject

@property (nonatomic, weak) TX500FT8AudioEngine *audioEngine;

// Active QSO State
@property (nonatomic, assign, readonly) TX500FT8QSOPhase qsoPhase;
@property (nonatomic, copy, readonly) NSString *activeDXCall;
@property (nonatomic, copy, readonly) NSString *activeDXGrid;
@property (nonatomic, copy, readonly) NSString *sentReport;
@property (nonatomic, copy, readonly) NSString *rcvdReport;
@property (nonatomic, copy, readonly) NSString *activeDXCountry;
@property (nonatomic, copy, readonly) NSString *activeDXFlag;
@property (nonatomic, assign, readonly) double activeDXDistanceKm;
@property (nonatomic, assign, readonly) BOOL isQSOActive;

// Algorithm 1: Auto-CQ Loop Configuration & Status
@property (nonatomic, assign) BOOL isAutoCQActive;
@property (nonatomic, assign) NSInteger autoCQTargetCount;  // e.g. 5, 10, 20 (0 = infinite)
@property (nonatomic, assign, readonly) NSInteger autoCQCurrentCount;
@property (nonatomic, assign) BOOL resumeAutoCQAfterQSO;
@property (nonatomic, copy, readonly) NSString *autoCQStatus;

// Auto-Seq & Call 1st Configuration (WSJT-X Standard)
@property (nonatomic, assign) BOOL autoSeqEnabled;   // default YES: WSJT-X standard automatic QSO sequencing
@property (nonatomic, assign) BOOL callFirstEnabled; // default YES: Automatically answer callers responding to our CQ

// Algorithm 2: Intelligent Auto-Hunter Configuration & Status
@property (nonatomic, assign) BOOL isAutoHunterActive;
@property (nonatomic, assign) TX500FT8HunterCriteria autoHunterCriteria;
@property (nonatomic, assign) float autoHunterMinSNR;       // default -18.0 dB
@property (nonatomic, assign) BOOL autoHunterSkipWorked;    // default YES
@property (nonatomic, copy) NSString *autoHunterContinent;  // @"ALL", @"EU", @"AS", @"NA", etc.
@property (nonatomic, copy, readonly) NSString *autoHunterStatus;
// Maximum number of TX-retry cycles per callsign before giving up (1–9, default 2).
// Persisted in TX500_MaxReplyAttempts NSUserDefaults key.
@property (nonatomic, assign) NSInteger maxReplyAttempts;


// Session History & ADIF Log
@property (nonatomic, strong, readonly) NSArray<TX500FT8LoggedQSO *> *sessionLog;
@property (nonatomic, strong, readonly) NSSet<NSString *> *workedCallsigns;
@property (nonatomic, strong, readonly) NSSet<NSString *> *workedGrids;

// Callbacks
@property (nonatomic, copy, nullable) void (^onQSOStateChanged)(TX500FT8QSOPhase phase, NSString *statusText);
@property (nonatomic, copy, nullable) void (^onDXStationEngaged)(NSString *dxCall, NSString *dxGrid, NSString *report, TX500FT8QSOPhase phase);
@property (nonatomic, copy, nullable) void (^onQSOLogged)(TX500FT8LoggedQSO *qso);
@property (nonatomic, copy, nullable) void (^onAlgorithmStatusUpdated)(NSString *autoCQStatus, NSString *autoHunterStatus);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);

// High-Level Operator Controls
- (void)startAutoCQWithLimit:(NSInteger)count;
- (void)stopAutoCQ;
- (void)setCallingCQState:(BOOL)callingCQ;

- (void)startAutoHunter;
- (void)stopAutoHunter;
- (void)evaluateAutoHunterCandidates;

// Last Decoded Slot Messages
@property (nonatomic, strong, readonly, nullable) NSArray<TX500FT8Message *> *lastDecodedMessages;
@property (nonatomic, assign, readonly) NSInteger lastDecodedParity;

- (void)engageStation:(TX500FT8Message *)targetMessage;
- (void)engageCaller:(TX500FT8Message *)caller inReplyToSlotParity:(NSInteger)slotParity;
- (void)abortQSO;
- (void)advanceToNextQSOStep;

// Ingest Incoming Decoded Slot
- (void)processDecodedSlot:(NSArray<TX500FT8Message *> *)messages parity:(NSInteger)parity;

// Export Log to ADIF
+ (NSString *)qsoLogbookADIFPath;
- (void)logCompletedQSOToADIF:(TX500FT8LoggedQSO *)qso;
- (NSString *)generateADIFExport;
- (void)clearSessionLog;

@end

NS_ASSUME_NONNULL_END
