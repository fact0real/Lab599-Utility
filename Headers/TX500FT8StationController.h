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

@interface TX500FT8StationController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate>

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong, readonly) TX500FT8AudioEngine *audioEngine;
@property (nonatomic, strong, readonly) TX500FT8AutoEngine *autoEngine;
@property (nonatomic, strong, readonly) TX500FT8WaterfallView *waterfallView;

// Hardware & Host Integration
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) BOOL (^pttControlHandler)(BOOL pttActive);
@property (nonatomic, copy, nullable) NSString * _Nullable (^catQueryHandler)(NSString *catCommand, NSTimeInterval timeout);
@property (nonatomic, copy, nullable) void (^stationStateChangedHandler)(BOOL isMonitoring);
/// Follows the complete user-requested Digital run, including audio setup and
/// failure diagnostics that occur before monitoring becomes active.
@property (nonatomic, copy, nullable) void (^diagnosticSessionStateChangedHandler)(BOOL isRunning);

// Lifecycle & Protocol
@property (nonatomic, assign) tx500_ft8_protocol_t protocol;
- (void)selectProtocol:(tx500_ft8_protocol_t)protocol;
- (void)startStation;
- (void)stopStation;
- (void)prepareRadioForDigitalMode;
- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode;
- (void)refreshRadioFrequency;
- (void)reloadStationPreferences;
- (void)setSimulationEnabled:(BOOL)enabled;
- (void)startSimulationPreview;
- (void)refreshAudioTab;
- (void)updateAudioDeviceMenus;
- (void)toggleWideTables:(nullable id)sender;
- (void)toggleFullHeight:(nullable id)sender;

@end

NS_ASSUME_NONNULL_END
