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
@property (nonatomic, assign) NSInteger wpm; // 10 to 45 WPM, default 22
@property (nonatomic, assign) double sidetonePitchHz; // default 650 Hz
@property (nonatomic, assign) BOOL sidetoneEnabled;
@property (nonatomic, assign) float sidetoneVolume;
@property (nonatomic, assign) BOOL useCutNumbers; // 599 -> 5NN
@property (nonatomic, copy) NSString *myCallsign; // e.g. "EP2AES"

// Live State
@property (nonatomic, assign, readonly) BOOL isTransmitting;
@property (nonatomic, copy, readonly) NSString *activeBufferText;
@property (nonatomic, copy, readonly) NSString *currentlyTransmittingChar;
@property (nonatomic, strong, readonly) NSArray<NSString *> *sentHistory;

// Auto-CQ Loop
@property (nonatomic, assign, readonly) BOOL isAutoCQActive;
@property (nonatomic, assign) NSInteger autoCQIntervalSeconds; // default 4
@property (nonatomic, assign, readonly) NSInteger autoCQCountdown;

// Macros
@property (nonatomic, strong) NSMutableArray<TX500CWMacro *> *macroList;

// Serial Port & Logging Callbacks
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) void (^onTransmitStateChanged)(BOOL transmitting, NSString *activeText);

// Methods
- (void)transmitText:(NSString *)text targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;
- (void)abortTransmission;
- (void)triggerMacroAtIndex:(NSInteger)index targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;

// Auto-CQ
- (void)startAutoCQWithTemplate:(NSString *)tmpl targetCall:(NSString *)call;
- (void)stopAutoCQ;

// Template Expansion
- (NSString *)expandTemplate:(NSString *)tmpl targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth;

@end

NS_ASSUME_NONNULL_END
