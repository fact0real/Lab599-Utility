//
//  TX500CWKeyer.h
//  Lab599 Utility
//
//  Native Kenwood CAT Morse Keyer & Macro Automation Engine for Lab599 TX-500
//  Supports Kenwood KS (speed) and KY (text) over CAT, PTT control with watchdog,
//  local audio sidetone generator, dynamic macro token expansion, and Auto-CQ repeat loop.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Lab599SerialPort.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500CWMacro : NSObject
@property (nonatomic, assign) NSInteger macroId; // 1 to 8 (F1 to F8)
@property (nonatomic, copy) NSString *label;
@property (nonatomic, copy) NSString *templateString;
+ (instancetype)macroWithId:(NSInteger)mId label:(NSString *)label template:(NSString *)tmpl;
@end

@interface TX500CWKeyer : NSObject

// Operational Configuration
@property (nonatomic, assign) NSInteger wpm; // 3 to 45 WPM, default 22
@property (nonatomic, assign) double sidetonePitchHz; // default 650 Hz
@property (nonatomic, assign) BOOL sidetoneEnabled;
@property (nonatomic, assign) float sidetoneVolume;
@property (nonatomic, assign) BOOL useCutNumbers; // 599 -> 5NN
@property (nonatomic, copy) NSString *myCallsign; // Empty until set; {MYCALL} macros need it.
// Hard transmit time-out, independent of the sidetone, the release timers and the main thread: a
// message longer than this is refused up front, and whatever is still on the air when it elapses
// is silenced and released (RX;). Defaults: 120 s for a message, 15 s for the tuning carrier.
@property (nonatomic, assign) NSTimeInterval maximumTransmitSeconds;
@property (nonatomic, assign) NSTimeInterval maximumCarrierSeconds;

// Live State
@property (nonatomic, assign, readonly) BOOL isTransmitting;
@property (nonatomic, copy, readonly) NSString *activeBufferText;
@property (nonatomic, copy, readonly) NSString *currentlyTransmittingChar;
@property (nonatomic, strong, readonly) NSArray<NSString *> *sentHistory;

// Auto-CQ Loop
@property (nonatomic, assign, readonly) BOOL isAutoCQActive;
@property (nonatomic, assign) NSInteger autoCQIntervalSeconds; // default 4
@property (nonatomic, assign, readonly) NSInteger autoCQCountdown;
// Auto-CQ stops on its own after this many calls, or this long after it started (0 = no limit).
@property (nonatomic, assign) NSInteger autoCQMaximumCalls; // default 10; 0 = no limit
@property (nonatomic, assign) NSTimeInterval autoCQMaximumSeconds; // default 600; 0 = no limit
@property (nonatomic, assign, readonly) NSInteger autoCQCallsSent;

// Macros
@property (nonatomic, strong) NSMutableArray<TX500CWMacro *> *macroList;

// Serial Port & Logging Callbacks
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) void (^onTransmitStateChanged)(BOOL transmitting, NSString *activeText);
// YES while Practice / Sim is on: the keyer then plays the local sidetone only and never opens or
// feeds the radio's audio output, so nothing can reach the transmitter. Set by the station.
@property (nonatomic, copy, nullable) BOOL (^practiceModeActive)(void);

@property (nonatomic, copy, nullable) NSString *radioOutputDeviceUID;
// The other half of the radio's USB codec, found by the station from the chosen CW input. Used
// only when the profile names no Radio transmit output (radioOutputDeviceUID).
@property (nonatomic, copy, nullable) NSString *pairedRadioOutputDeviceUID;
// The output that will carry the transmit audio: the profile's radioOutputDeviceUID, else the
// pair, else nil. Never a device picked by its transport (the first USB output of the Mac).
- (nullable NSString *)radioAudioTargetUID;
// YES only when the radio's output queue is open and running; the station calls it before keying.
- (BOOL)ensureRadioAudioReady;
@property (nonatomic, copy, nullable) NSString *txPrefixCommand;
@property (nonatomic, copy, nullable) NSString *rxSuffixCommand;
// Called on the main thread after the time-out silenced and released the radio.
@property (nonatomic, copy, nullable) void (^onTransmitTimedOut)(NSTimeInterval limitSeconds);

// Methods
+ (nullable NSString *)findBestUSBAudioOutputUID;
- (void)transmitText:(NSString *)text targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;
- (void)abortTransmission;
- (void)triggerMacroAtIndex:(NSInteger)index targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;
- (void)startContinuousCarrierWithPitchHz:(double)pitch;
- (void)stopContinuousCarrier;

// Auto-CQ
- (void)startAutoCQWithTemplate:(NSString *)tmpl targetCall:(NSString *)call;
- (void)stopAutoCQ;
// The station feeds the decoder's text; a station calling us ("<MYCALL> DE ...") ends Auto-CQ.
- (void)noteDecodedText:(NSString *)text;

// Template Expansion
- (NSString *)expandTemplate:(NSString *)tmpl targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;
// YES when the template uses {MYCALL} and no callsign is set: transmitText would refuse it.
- (BOOL)templateNeedsMissingCallsign:(NSString *)tmpl;

@end

NS_ASSUME_NONNULL_END
