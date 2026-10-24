// SPDX-License-Identifier: GPL-3.0-or-later
// SSTV receive engine: the native SSTV core (Sources/sstv1) behind an Objective-C face.
// Receive only. Audio comes from a source: the radio (an Audio Queue on the station's input
// route) or a WAV file. A picture decoded from a file is practice and is never logged.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// What the mode selector can ask for. Auto reads the VIS header; the others decode without it.
typedef NS_ENUM(NSInteger, TX500SSTVModeChoice) {
    TX500SSTVModeAuto = 0,
    TX500SSTVModeMartin1,
    TX500SSTVModeMartin2,
    TX500SSTVModeScottie1,
    TX500SSTVModeScottie2,
    TX500SSTVModeRobot36,
    TX500SSTVModePD90,
    TX500SSTVModePD120,
};

/// The colour scale of Robot and PD pictures (A11): Barber's studio scale, or full range.
typedef NS_ENUM(NSInteger, TX500SSTVColourScale) {
    TX500SSTVColourScaleStudio = 0,
    TX500SSTVColourScaleFull,
};

/// Where Scottie puts its separators (A1): found from the picture, Barber's, or Open-SSTV's.
typedef NS_ENUM(NSInteger, TX500SSTVScottieLayout) {
    TX500SSTVScottieLayoutAuto = 0,
    TX500SSTVScottieLayoutBarber,
    TX500SSTVScottieLayoutOpen,
};

/// What a notice from the receiver is about (the core's sstv_note), so the screen can say it.
typedef NS_ENUM(NSInteger, TX500SSTVNoticeKind) {
    TX500SSTVNoticeOther = 0,
    TX500SSTVNoticeVIS,                 // a VIS was read: a picture starts
    TX500SSTVNoticeVISRejected,         // the VIS failed its parity check
    TX500SSTVNoticeVISUnknown,          // a VIS code that is not one of the modes here
    TX500SSTVNoticeVIS16Bit,            // a 16-bit VIS (MMSSTV extended modes): not supported
    TX500SSTVNoticeHeaderInPicture,     // a header inside a picture that still has its syncs: it goes on
    TX500SSTVNoticeManualStart,         // no VIS: the picture starts with the mode chosen by hand
    TX500SSTVNoticeManualNoSync,        // chosen mode: a signal, but no sync of that mode in 10 lines
    TX500SSTVNoticeManualNoise,         // chosen mode: only noise in 10 lines
    TX500SSTVNoticePeriodMismatch,      // the syncs do not fall on the mode's period
    TX500SSTVNoticeRobot36Variant,      // Robot 36 with ~300 ms lines: not Barber's form, no picture
    TX500SSTVNoticeSyncLost,            // 30 lines with no sync, and at least 12 s: the picture is closed
    TX500SSTVNoticeClosedByNewVIS,      // a new VIS after the picture had lost its syncs
    TX500SSTVNoticeSlantNominal,        // the slant fit left few syncs on its line: the mode's period is used
    TX500SSTVNoticeNoRows,              // the input ended before the picture's first line: no picture
};

@interface TX500SSTVNotice : NSObject
@property (nonatomic, readonly) TX500SSTVNoticeKind kind;
@property (nonatomic, readonly) double time;            // seconds of audio since start
@property (nonatomic, readonly, copy) NSString *modeName;
@property (nonatomic, readonly) double offsetHz;
@property (nonatomic, readonly, copy) NSString *text;    // in English, for the screen
- (instancetype)initWithKind:(TX500SSTVNoticeKind)kind time:(double)time modeName:(NSString *)modeName
                    offsetHz:(double)offsetHz text:(NSString *)text;
@end

/// The audio of one reception, kept so that it can be decoded again or exported (
/// "Decode again from buffer"). Mono, 16 bits, at the rate it came in (12 kHz from the radio).
@interface TX500SSTVRecording : NSObject
@property (nonatomic, readonly, copy) NSData *samples;      // int16, native order
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) double startTime;           // seconds of the engine's input where it starts
@property (nonatomic, copy) NSString *modeKey;              // the picture it holds, as first decoded
@property (nonatomic, copy) NSDate *endUTC;
@property (nonatomic) BOOL fromFile;
@property (nonatomic) BOOL keep;                            // never expires
@property (nonatomic, copy, nullable) NSURL *fileURL;       // its copy on disk, if any
/// When its samples were heard: @[sample offset, seconds since 1970] pairs, in order (a sleep or a
/// gap inside it starts a new pair). Empty: it ends at endUTC, without gaps.
@property (nonatomic, copy) NSArray<NSArray<NSNumber *> *> *timeAnchors;
- (NSDate *)dateAtSample:(double)offset;
- (NSDate *)startUTC;
- (instancetype)initWithSamples:(NSData *)samples sampleRate:(double)rate startTime:(double)start;
- (double)duration;
- (NSUInteger)byteSize;
/// The original audio as a WAV (PCM, 16 bits, mono), for other programs (MMSSTV, QSSTV, fldigi).
- (BOOL)writeWAVToURL:(NSURL *)url error:(NSError **)error;
+ (nullable TX500SSTVRecording *)recordingFromWAVAtURL:(NSURL *)url error:(NSError **)error;
@end

/// A received picture. Its pixels are RGB, 8 bits each, row by row.
@interface TX500SSTVPicture : NSObject
@property (nonatomic, readonly, copy) NSString *modeKey;    // "M1"
@property (nonatomic, readonly, copy) NSString *modeName;   // "Martin M1"
@property (nonatomic, readonly) NSInteger width, height, rowsReceived;
@property (nonatomic, readonly) BOOL complete;
@property (nonatomic, readonly, copy) NSData *rgb;
@property (nonatomic, readonly, copy) NSDate *endUTC;       // when the picture ended
@property (nonatomic, readonly) double offsetHz, slantPPM;
@property (nonatomic, readonly) BOOL fromFile;              // practice: never logged
@property (nonatomic, readonly, copy) NSString *sourceName;
@property (nonatomic, copy, nullable) NSURL *savedURL;      // the gallery copy
/// Its audio, as the engine hands it over. The screen gives it to the store and lets it go (the
/// store alone keeps audio in memory, the last few: DEC-4); then receptionIdentifier finds it.
@property (nonatomic, strong, nullable) TX500SSTVRecording *recording;
@property (nonatomic, copy, nullable) NSString *receptionIdentifier;
@property (nonatomic) double startTime;                     // first line, seconds of the engine's input
@property (nonatomic, copy, nullable) NSDate *startUTC;     // when the first line was heard
- (instancetype)initWithModeKey:(NSString *)key modeName:(NSString *)name width:(NSInteger)w height:(NSInteger)h
                   rowsReceived:(NSInteger)rows complete:(BOOL)complete rgb:(NSData *)rgb endUTC:(NSDate *)end
                       offsetHz:(double)offsetHz slantPPM:(double)slant fromFile:(BOOL)fromFile sourceName:(NSString *)source;
- (NSBitmapImageRep *)bitmap;
- (NSImage *)image;
- (BOOL)writePNGToURL:(NSURL *)url error:(NSError **)error;
@end

/// An audio source. It calls deliver with mono float samples at sampleRate, from any thread, in
/// order, and finished once at the end (a file ends; the radio ends when stopped).
@protocol TX500SSTVAudioSource <NSObject>
@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) BOOL isLive;               // the radio: YES; a file: NO
@property (nonatomic, readonly, copy) NSString *sourceName;
@optional
- (nullable NSString *)inputFailure;
/// For audio recorded earlier (decoding again): when its samples were heard, as pairs
/// @[sample offset, seconds since 1970], in order; each holds until the next. The pictures get
/// the time they were really received, not the time of decoding. Without it: now.
- (NSArray<NSArray<NSNumber *> *> *)timeAnchors;
/// For live audio: when the first sample of the block being delivered was captured (the input's
/// time stamp), asked during the delivery. After a sleep of the Mac or a gap in the audio the
/// engine anchors its clock to it again, so that a picture's time is the real one (DEC-10).
- (nullable NSDate *)dateOfCurrentBlock;
@required
- (BOOL)startDelivering:(void (^)(const float *samples, NSUInteger count))deliver
               finished:(void (^)(void))finished
                  error:(NSError **)error;
- (void)stop;
@end

/// A recording played back as a source (decode again). Synchronous.
@interface TX500SSTVRecordingSource : NSObject <TX500SSTVAudioSource>
- (instancetype)initWithRecording:(TX500SSTVRecording *)recording;
@end

/// A WAV file (PCM 16 bits or float), read with the core's reader. Synchronous by default (the
/// tests); with asynchronous set, on a background queue.
@interface TX500SSTVFileSource : NSObject <TX500SSTVAudioSource>
- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
@property (nonatomic) BOOL asynchronous;
@property (nonatomic) NSUInteger blockFrames;              // default: 0.25 s
@end

/// The radio: an Audio Queue input (mono float, 12 kHz, shared, not exclusive) on a device UID.
/// It opens the microphone permission path: it is never started by the tests.
/// The radio's audio input: only the device the operator chose for the radio (its UID). With no
/// UID, "default", or a device that is not connected, it opens nothing and says why (SEG-2).
@interface TX500SSTVRadioSource : NSObject <TX500SSTVAudioSource>
- (instancetype)initWithDeviceUID:(nullable NSString *)uid;
@property (nonatomic, readonly, copy, nullable) NSString *deviceName;   // nil: not found
@property (nonatomic, readonly) BOOL builtIn;                           // the Mac's own input
+ (nullable NSDictionary *)inputDeviceWithUID:(NSString *)uid;          // @{name, builtIn}, or nil
/// Every input on this Mac: @{uid, name, builtIn, virtual}, in the system's order.
+ (NSArray<NSDictionary *> *)inputDevices;
@end

@interface TX500SSTVEngine : NSObject
@property (atomic, readonly, copy, nullable) NSString *lastInputFailure;
@property (nonatomic) TX500SSTVModeChoice modeChoice;
@property (nonatomic) TX500SSTVColourScale colourScale;
@property (nonatomic) TX500SSTVScottieLayout scottieLayout;
/// The line period: fitted to the syncs (YES, default), or the nominal one times (1 + ppm / 1e6).
@property (nonatomic) BOOL fitSlant;
@property (nonatomic) double slantPPM;
/// Seconds of input audio kept in memory, so that each picture carries its own recording (300).
@property (nonatomic) double ringSeconds;
@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly, nullable) id<TX500SSTVAudioSource> source;
/// Where the callbacks go; nil calls them on the decoding thread (the tests).
@property (nonatomic, strong, nullable) dispatch_queue_t callbackQueue;
/// The picture being received, drawn so far, at most every progressInterval seconds of audio.
@property (nonatomic) double progressInterval;             // default 0.5 s
@property (nonatomic, copy, nullable) void (^onProgress)(NSString *modeName, NSInteger rows, NSInteger height, NSBitmapImageRep *partial);
@property (nonatomic, copy, nullable) void (^onPicture)(TX500SSTVPicture *picture);
@property (nonatomic, copy, nullable) void (^onNotice)(TX500SSTVNotice *notice);
@property (nonatomic, copy, nullable) void (^onStopped)(void);

/// Starts decoding from a source, with the settings above.
- (BOOL)startWithSource:(id<TX500SSTVAudioSource>)source error:(NSError **)error;
/// The settings above changed while it runs: they apply from the next picture, without stopping
/// the input or losing the last minutes (DEC-2). A picture being received goes on as it began;
/// the last seconds before the change are decoded again with the new settings, so a header that
/// was arriving is not lost.
- (void)applySettings;
/// A picture is being received now (the new settings then wait for its end).
@property (nonatomic, readonly) BOOL receiving;
/// Settings changed while a picture was being received, not applied yet.
@property (nonatomic, readonly) BOOL settingsWaiting;
/// Stops: a picture in progress is finished as incomplete.
- (void)stop;
/// The samples, as a source delivers them (public for the tests). Blocks from a source that has
/// been replaced are ignored: each start is a run of its own (DEC-3, SEG-13).
- (void)feedSamples:(const float *)samples count:(NSUInteger)count;
- (void)finishInput;
/// The last ringSeconds of input, whether a picture was found in it or not: the case of a VIS that
/// was missed (decode it again with the mode chosen by hand). Nil before any input. They stay in
/// memory until the app quits, also after stop; a start that opens the input writes
/// them anew, and one that opens nothing leaves them as they were. Never on disk unless kept.
- (nullable TX500SSTVRecording *)lastMinutes;
/// Their size and when they end, without copying them (for the list).
- (NSUInteger)lastMinutesByteSize;
- (nullable NSDate *)lastMinutesEndUTC;
@end

/// The WAV reader's reason for refusing a file (the core's own words, in Catalan), in English for the
/// screen; the SSTV and fax screens both say it so.
NSString *TX500WAVReasonInEnglish(const char *reason);

NS_ASSUME_NONNULL_END
