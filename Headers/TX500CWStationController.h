//
//  TX500CWStationController.h
//  Lab599 Utility
//
//  Complete CW Workstation & Semi-Automated QSO Studio Controller
//  Integrates CoreAudio DSP Goertzel decoding (AD-508 USB-C), Kenwood CAT keying,
//  real-time audio scope & 2D scrolling waterfall, 3 kHz wideband multi-channel decoding,
//  live RX audio sidetone monitor, VFO tuning & amateur band chips,
//  per-message recording, interactive semi-automated QSO copilot, and ADIF logging.
//

#import <Cocoa/Cocoa.h>
#import "TX500CWAudioDecoder.h"
#import "TX500CWKeyer.h"
#import "TX500CWQSOAssistant.h"
#import "TX500CWSpectrumView.h"
#import "TX500AudioEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500CWStationController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong, readonly) NSView *view;
@property (nonatomic, strong, readonly) TX500CWAudioDecoder *decoder;
@property (nonatomic, strong, readonly) TX500CWKeyer *keyer;
@property (nonatomic, strong, readonly) TX500CWQSOAssistant *assistant;
@property (nonatomic, strong, readonly) TX500AudioEngine *audioEngine;

// Hardware & Host Integration
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^prepareCWModeHandler)(void (^completion)(BOOL verified));
@property (nonatomic, copy, nullable) NSString *(^catQueryHandler)(NSString *catCommand, NSTimeInterval timeout);
/// Called on the main thread whenever the decoder starts or stops (isListening changed).
@property (nonatomic, copy, nullable) void (^decoderStateChangedHandler)(BOOL isListening);

// Live Transmit Telemetry
@property (nonatomic, assign, readonly) double liveTXPowerWatts;
@property (nonatomic, assign, readonly) double liveTXSWR;

// Frequency & Band Management
@property (nonatomic, assign) uint64_t currentDialFrequencyHz;
/// YES when the radio accepted the new frequency; nothing is shown as tuned otherwise.
- (BOOL)tuneToFrequencyHz:(uint64_t)freqHz;
- (BOOL)stepFrequencyHz:(int64_t)stepHz;
- (void)selectAmateurBand:(NSString *)band;
- (void)answerWidebandChannel:(TX500CWChannelState *)channel;

// Audio Monitor & Recording
@property (nonatomic, assign, readonly) BOOL isMonitoringAudio;
@property (nonatomic, assign, readonly) BOOL isRecordingAudio;
- (void)startAudioMonitor;
- (void)stopAudioMonitor;
- (void)toggleAudioMonitor;
- (void)startRecordingMessage;
- (void)stopRecordingMessage;
- (void)toggleRecording;

// Manual Transmit / Tune Control
@property (nonatomic, assign, readonly) BOOL isManualTuneActive;
- (void)toggleManualTransmit;
- (void)stopManualTransmit;
- (void)stopManualTune;

// Lifecycle
- (void)startStation;
- (void)stopStation;
- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode;
/// Supplies a default only until the operator chooses an input in CW Station.
- (void)applyStationInputDeviceUID:(nullable NSString *)uid;
/// Switches the transceiver to CW mode (MD3;) via CAT unless the operator chose a custom mode.
- (void)prepareRadioForCWMode;
- (void)noteRadioReleaseConfirmed:(BOOL)confirmed;
/// The radio's own output for a CW input: the same UID when the input is also an output, else the
/// one output of its AppleUSBAudioEngine family. Nil unless the input is the radio's USB audio
/// (isPreferredUSBAudio) or a USB radio interface named Digirig, SignaLink, C-Media or "codec"; nil for
/// System Audio, and when two outputs share the family.
+ (nullable NSString *)pairedRadioOutputUIDForInputUID:(nullable NSString *)inputUID
                                         inputDevices:(NSArray<NSDictionary<NSString *, NSString *> *> *)inputs
                                        outputDevices:(NSArray<TX500AudioDeviceItem *> *)outputs;
@property (nonatomic, copy) NSString *operatingMode;
@property (nonatomic) BOOL userHasChosenCustomMode;

@end

NS_ASSUME_NONNULL_END
