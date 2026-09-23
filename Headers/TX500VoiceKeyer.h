#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSError *TXVoiceError(NSString *message);
FOUNDATION_EXPORT NSArray<NSDictionary *> *TXVoiceDevices(BOOL input);
FOUNDATION_EXPORT BOOL TXVoiceDeviceAvailable(NSString *uid, BOOL input);

// Radio methods are synchronous and called only on the keyer's private worker.
@protocol TX500VoiceRadio <NSObject>
- (nullable NSDictionary *)readState:(NSError **)error;
- (BOOL)tuneFrequency:(uint64_t)frequency mode:(NSInteger)mode error:(NSError **)error;
- (BOOL)setTransmit:(BOOL)transmit error:(NSError **)error;
- (void)close;
@end
@interface TX500VoiceCATRadio : NSObject <TX500VoiceRadio>
- (instancetype)initWithPort:(NSString *)path;
- (nullable NSString *)query:(NSString *)command error:(NSError **)error;
- (BOOL)send:(NSString *)command error:(NSError **)error;
@end

@interface TX500VoiceClip : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic) double duration;
@property(nonatomic, copy) NSArray<NSNumber *> *peaks;
@end
@interface TX500VoiceLibrary : NSObject
@property(nonatomic, readonly) NSArray<TX500VoiceClip *> *clips;
@property(nonatomic, readonly) NSURL *directory;
- (instancetype)initWithDirectory:(NSURL *)directory;
- (nullable TX500VoiceClip *)importURL:(NSURL *)URL title:(NSString *)title role:(NSString *)role error:(NSError **)error;
- (BOOL)renameClip:(TX500VoiceClip *)clip title:(NSString *)title role:(NSString *)role error:(NSError **)error;
- (BOOL)removeClip:(TX500VoiceClip *)clip error:(NSError **)error;
@end

// Explicit input/output UIDs; input-only capture records locally, bridge mode is
// used for receive monitoring or the operator's live microphone. Never defaults.
@interface TX500VoiceAudioIO : NSObject
@property(nonatomic, readonly) BOOL running;
@property(nonatomic, readonly) double level;
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) BOOL overflowed;
@property(nonatomic) float gain;
- (BOOL)startInput:(NSString *)input output:(nullable NSString *)output record:(BOOL)record error:(NSError **)error;
- (void)stop;
- (BOOL)writeRecording:(NSURL *)URL error:(NSError **)error;
@end

typedef NS_ENUM(NSInteger, TX500VoiceState) {
    TXVoiceIdle, TXVoiceChecking, TXVoiceLead, TXVoicePlaying, TXVoiceTail,
    TXVoiceReleasing, TXVoiceListening, TXVoiceLive, TXVoiceStopping, TXVoiceFault
};
@protocol TX500VoicePlayback <NSObject>
@property(nonatomic, readonly) double duration;
@property(nonatomic, readonly) double currentTime;
@property(nonatomic) float volume;
- (BOOL)prepareURL:(NSURL *)URL device:(NSString *)uid error:(NSError **)error;
- (BOOL)play;
- (void)stop;
@property(nonatomic, copy, nullable) void (^completion)(BOOL success);
@end
@interface TX500VoicePlayer : NSObject <TX500VoicePlayback>
@end

// Public controls and callbacks belong to the main thread. CAT runs on a private
// serial queue. Generation tokens invalidate every delayed continuation on Stop.
@interface TX500VoiceKeyer : NSObject
@property(nonatomic, readonly) TX500VoiceState state;
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) BOOL connected;
@property(nonatomic, readonly) BOOL radioBusy;
@property(nonatomic, readonly) NSDictionary *radioState;
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) double progress;
@property(nonatomic, readonly) double remaining;
@property(nonatomic, readonly) double microphoneLevel;
@property(nonatomic, readonly) NSInteger completedCalls;
@property(nonatomic, copy) NSString *outputUID;
@property(nonatomic, copy) NSString *microphoneUID;
@property(nonatomic) double listenSeconds; // 3...60 seconds, measured after confirmed RX
@property(nonatomic) double variationSeconds; // 0...2, never reduces listen below 3
@property(nonatomic) double leadSeconds; // 0.10...1
@property(nonatomic) double tailSeconds; // 0.10...1, after playback completion
@property(nonatomic) NSInteger maximumCalls;
@property(nonatomic) float gain;
@property(nonatomic) BOOL lineInputConfirmed;
@property(nonatomic, copy, nullable) void (^changed)(void);
@property(nonatomic, copy, nullable) void (^log)(NSString *message);
@property(nonatomic, copy) BOOL (^deviceAvailable)(NSString *uid, BOOL input);
- (instancetype)initWithRadio:(id<TX500VoiceRadio>)radio player:(id<TX500VoicePlayback>)player;
- (void)connectFrequency:(uint64_t)frequency mode:(NSInteger)mode apply:(BOOL)apply;
- (void)startClip:(TX500VoiceClip *)clip repeat:(BOOL)repeat;
- (void)startTalking;
- (void)stop;
- (BOOL)disconnectAndWait;
@end
NS_ASSUME_NONNULL_END
