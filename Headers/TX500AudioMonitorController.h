//
//  TX500AudioMonitorController.h
//  Lab599 Utility
//
//  Complete Live Radio Audio Monitoring & DSP Studio Controller
//  Specially designed for Lab599 Discovery TX-500 over AD-508 USB-C Audio
//

#import <Cocoa/Cocoa.h>
#import "TX500AudioEngine.h"
#import "TX500AudioVisualizerView.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500AudioMonitorController : NSObject

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong, readonly) TX500AudioEngine *engine;
@property (nonatomic, strong, readonly) TX500AudioVisualizerView *visualizerView;

// Host Integration Callbacks
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) void (^onMonitoringStateChanged)(BOOL isMonitoring);
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) NSString * _Nullable (^catQueryHandler)(NSString *catCommand, NSTimeInterval timeout);
@property (nonatomic, copy, nullable) void (^onQuickLogRequested)(uint64_t freqHz, NSString *mode);

// Radio State
@property (nonatomic, assign, readonly) uint64_t currentFrequencyHz;
@property (nonatomic, copy, readonly) NSString *currentMode;
@property (nonatomic, assign, readonly) NSInteger currentSMeter;

// Lifecycle & Actions
- (void)startController;
- (void)stopController;
- (void)pauseTabUI;
- (void)resumeTabUI;
- (void)toggleMonitoring;
- (void)setRadioMode:(NSString *)mode;
- (void)tuneRadioToFrequencyHz:(uint64_t)freqHz;
- (void)bookmarkCurrentFrequencyWithLabel:(nullable NSString *)label;

@end

NS_ASSUME_NONNULL_END
