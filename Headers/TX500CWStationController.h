//
//  TX500CWStationController.h
//  Lab599 Utility
//
//  Complete CW Workstation & Semi-Automated QSO Studio Controller
//  Integrates CoreAudio DSP Goertzel decoding (AD-508 USB-C), Kenwood CAT keying,
//  real-time audio scope, CQ roster, interactive semi-automated QSO copilot,
//  and ADIF contact logging.
//

#import <Cocoa/Cocoa.h>
#import "TX500CWAudioDecoder.h"
#import "TX500CWKeyer.h"
#import "TX500CWQSOAssistant.h"
#import "TX500CWSpectrumView.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500CWStationController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong, readonly) TX500CWAudioDecoder *decoder;
@property (nonatomic, strong, readonly) TX500CWKeyer *keyer;
@property (nonatomic, strong, readonly) TX500CWQSOAssistant *assistant;

// Hardware & Host Integration
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
/// Called on the main thread whenever the decoder starts or stops (isListening changed).
@property (nonatomic, copy, nullable) void (^decoderStateChangedHandler)(BOOL isListening);

// Lifecycle
- (void)startStation;
- (void)stopStation;
- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode;

@end

NS_ASSUME_NONNULL_END
