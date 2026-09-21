//
//  TX500FT8AudioEngine.h
//  Lab599 Utility
//
//  Real-Time CoreAudio Slot-Synchronized DSP Engine for FT8
//  Supports AD-508 USB-C Audio / DATA Soundcard In & Out,
//  UTC 15-second slot synchronization, background LDPC decoding,
//  continuous GFSK tone modulation synthesis, live waterfall FFT streaming,
//  and synthetic FT8 RF simulation.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import "TX500FT8Message.h"
#import "tx500_ft8_shim.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500FT8SlotParity) {
    TX500FT8SlotParityEven = 0, // :00 and :30 seconds
    TX500FT8SlotParityOdd  = 1, // :15 and :45 seconds
    TX500FT8SlotParityAuto = 2  // Alternates automatically
};

@interface TX500FT8AudioEngine : NSObject

// Station Identification
@property (nonatomic, copy) NSString *myCallsign;
@property (nonatomic, copy) NSString *myGrid;

// Audio Hardware Devices
@property (nonatomic, copy, nullable) NSString *selectedInputDeviceUID;
@property (nonatomic, copy, nullable) NSString *selectedOutputDeviceUID;
@property (nonatomic, strong, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *inputDevices;
@property (nonatomic, strong, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *outputDevices;
@property (nonatomic, assign, readonly) BOOL isAD508InputConnected;
@property (nonatomic, assign, readonly) BOOL isAD508OutputConnected;

// Radio & Frequencies
@property (nonatomic, assign) uint64_t dialFrequencyHz; // e.g. 14074000
@property (nonatomic, assign) float rxAudioFrequencyHz; // e.g. 1200 Hz
@property (nonatomic, assign) float txAudioFrequencyHz; // e.g. 1500 Hz
@property (nonatomic, assign) BOOL lockTxRxFrequencies;

// Operational State
@property (nonatomic, assign, readonly) BOOL isMonitoring;
@property (nonatomic, assign, readonly) BOOL isTransmitting;
@property (nonatomic, assign) BOOL isTransmitArmed;
@property (nonatomic, assign) TX500FT8SlotParity txSlotParity;
@property (nonatomic, assign) BOOL isSimulationMode;

// Timing & UTC Slot Status
@property (nonatomic, assign, readonly) double currentSlotSecond; // 0.00 to 14.99s
@property (nonatomic, assign, readonly) NSInteger currentSlotParity; // 0 (Even) or 1 (Odd)
@property (nonatomic, assign, readonly) double slotProgressFraction; // 0.0 to 1.0

// Active Transmit Payload
@property (nonatomic, copy) NSString *queuedTxMessage;

// CAT Integration Callbacks
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);

// Engine Event Callbacks
@property (nonatomic, copy, nullable) void (^onSlotTick)(double slotSec, NSInteger parity, double progress);
@property (nonatomic, copy, nullable) void (^onSlotTransition)(NSInteger parity, NSDate *utcStart);
@property (nonatomic, copy, nullable) void (^onDecodedMessages)(NSArray<TX500FT8Message *> *messages, NSInteger parity);
@property (nonatomic, copy, nullable) void (^onTransmitStateChanged)(BOOL transmitting, NSString *txText);
@property (nonatomic, copy, nullable) void (^onSpectrumUpdated)(const float *magnitudes, NSInteger count);
@property (nonatomic, copy, nullable) void (^onAudioDevicesChanged)(void);

// Live SWR Monitoring (polled from radio via CAT during TX)
@property (nonatomic, copy, nullable) void (^onSWRUpdated)(double swrValue); // called when SWR read from radio
@property (nonatomic, assign) double maxSWRThreshold; // 0 = disabled, >0 = abort TX if exceeded
@property (nonatomic, assign, readonly) double lastSWRReading;

// Control Methods
- (void)refreshAudioDevices;
- (void)restartAudioHardware;
- (BOOL)startMonitoring:(NSError **)error;
- (void)stopMonitoring;

// Transmit Control
- (void)armTransmitWithText:(NSString *)text parity:(TX500FT8SlotParity)parity;
- (void)disarmTransmit;
- (void)startTuneCarrier;
- (void)stopTuneCarrier;

// Continuous ADIF Logging
+ (NSString *)allDecodesADIFPath;
- (void)logDecodedMessagesToADIF:(NSArray<TX500FT8Message *> *)messages;

// Synthetic Signal Generator (Simulation)
- (void)injectSimulatedBandActivity;
- (void)injectSimulatedCallerResponse:(NSString *)dxCall report:(NSString *)report isRR73:(BOOL)isRR73;

@end

NS_ASSUME_NONNULL_END
