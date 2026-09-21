//
//  TX500FT8StationController.h
//  Lab599 Utility
//
//  Complete FT8 Digital Workstation & Autonomous QSO Studio Controller
//  Integrates CoreAudio DSP (AD-508 / DATA soundcard), pure C99 LDPC decoder,
//  Kenwood TS-2000 CAT PTT, 2D live waterfall, intelligent Auto-CQ & Auto-Hunter algorithms,
//  and session ADIF logging.
//

#import <Cocoa/Cocoa.h>
#import "TX500FT8AudioEngine.h"
#import "TX500FT8AutoEngine.h"
#import "TX500FT8WaterfallView.h"
#import "TX500FT8Message.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500FT8StationController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong, readonly) TX500FT8AudioEngine *audioEngine;
@property (nonatomic, strong, readonly) TX500FT8AutoEngine *autoEngine;
@property (nonatomic, strong, readonly) TX500FT8WaterfallView *waterfallView;

// Hardware & Host Integration
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^stationStateChangedHandler)(BOOL isMonitoring);

// Lifecycle
- (void)startStation;
- (void)stopStation;
- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode;
- (void)reloadStationPreferences;
- (void)setSimulationEnabled:(BOOL)enabled;

@end

NS_ASSUME_NONNULL_END
