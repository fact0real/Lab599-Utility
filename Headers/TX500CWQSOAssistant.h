//
//  TX500CWQSOAssistant.h
//  Lab599 Utility
//
//  Intelligent Semi-Automated CW QSO Assistant & ADIF Logger
//  Performs real-time stream analysis to extract CQ calls, station callsigns,
//  RST signal reports, and operator metadata. Drives an interactive semi-automated
//  QSO state machine and records completed contacts in standard ADIF 3.1 format.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500QSOState) {
    TX500QSOStateIdle = 0,
    TX500QSOStateCallingCQ,     // User called CQ (Run Mode)
    TX500QSOStateAnsweringCQ,   // User answering an heard CQ (S&P)
    TX500QSOStateExchangeReport,// Exchanging 5NN signal reports
    TX500QSOStateExchangeInfo,  // Exchanging Name / QTH
    TX500QSOStateSigningOff,    // Sending final 73 / SK
    TX500QSOStateCompleted      // QSO finished, ready to log
};

@interface TX500CWHeardStation : NSObject
@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, assign) double wpm;
@property (nonatomic, assign) double snrDb;
@property (nonatomic, assign) uint64_t frequencyHz;
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, assign) NSInteger count;
@end

@interface TX500QSOContact : NSObject
@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, copy) NSString *qsoDate;    // YYYYMMDD
@property (nonatomic, copy) NSString *timeOn;     // HHMMSS
@property (nonatomic, copy) NSString *band;       // e.g. "20m", "40m"
@property (nonatomic, assign) double frequencyMHz;
@property (nonatomic, copy) NSString *mode;       // "CW"
@property (nonatomic, copy) NSString *rstSent;    // "599" or "5NN"
@property (nonatomic, copy) NSString *rstRcvd;    // "599"
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qth;
@property (nonatomic, copy) NSString *notes;
- (NSString *)adifRecordString;
@end

@interface TX500CWQSOAssistant : NSObject

// Active QSO State
@property (nonatomic, assign) TX500QSOState qsoState;
@property (nonatomic, copy) NSString *activeTargetCallsign;
@property (nonatomic, copy) NSString *activeRstSent;
@property (nonatomic, copy) NSString *activeRstRcvd;
@property (nonatomic, copy) NSString *activeName;
@property (nonatomic, copy) NSString *activeQTH;
@property (nonatomic, copy) NSString *myCallsign; // default "EP2AES"

// Current Radio Telemetry
@property (nonatomic, assign) uint64_t currentFrequencyHz;
@property (nonatomic, copy) NSString *currentBand;

// Live Lists
@property (nonatomic, strong, readonly) NSArray<TX500CWHeardStation *> *heardStations;
@property (nonatomic, strong, readonly) NSArray<TX500QSOContact *> *loggedContacts;

// Suggested Action
@property (nonatomic, copy, readonly) NSString *stateDescription;
@property (nonatomic, copy, readonly) NSString *suggestedActionTitle;
@property (nonatomic, copy, readonly) NSString *suggestedActionMacro;
@property (nonatomic, assign, readonly) BOOL hasActionableStep;

// Callbacks
@property (nonatomic, copy, nullable) void (^onHeardStationsUpdated)(NSArray<TX500CWHeardStation *> *stations);
@property (nonatomic, copy, nullable) void (^onQSOStateChanged)(TX500QSOState newState, NSString *desc);
@property (nonatomic, copy, nullable) void (^onContactLogged)(TX500QSOContact *contact);

// Stream Ingestion
- (void)processDecodedTextStream:(NSString *)stream currentWPM:(double)wpm snrDb:(double)snr;

// Interactive Workflow Actions
- (void)selectAndAnswerStation:(TX500CWHeardStation *)station;
- (void)startCallingCQ;
- (void)advanceQSOStepWithAction:(void (^)(NSString *macroToTransmit))transmitBlock;
- (void)resetQSOState;
- (void)logCurrentQSO;

// Log Management
- (void)clearLog;
- (NSString *)generateFullADIFString;
- (BOOL)exportADIFToFileURL:(NSURL *)fileURL error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
