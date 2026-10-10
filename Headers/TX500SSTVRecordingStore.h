// SPDX-License-Identifier: GPL-3.0-or-later
// "Decode again from buffer". Every
// reception keeps its original audio: the last few in memory, always; the recent ones also on disk,
// in a space with a size cap that the operator chooses on the screen. When the space is full the
// oldest make room, unless marked Keep. Nothing piles up without a cap.
#import <Foundation/Foundation.h>
#import "TX500SSTVEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// One stored reception: its audio may be in memory, on disk, or both.
@interface TX500SSTVStoredReception : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *modeKey;
@property (nonatomic, readonly, copy) NSDate *startUTC, *endUTC;   // when its audio was heard
@property (nonatomic, readonly, copy) NSArray<NSArray<NSNumber *> *> *timeAnchors;   // its clock (TX500SSTVRecording)
@property (nonatomic, readonly) BOOL fromFile;
@property (nonatomic, readonly) BOOL keep;
@property (nonatomic, readonly) NSUInteger byteSize;
@property (nonatomic, readonly) BOOL inMemory, onDisk;
/// Its pictures' PNGs on disk, in bytes.
@property (nonatomic, readonly) unsigned long long pictureBytes;
/// The pictures decoded from this one recording: the first, and every "Decode again" (the audio
/// is stored once, however many pictures come from it). Their names in the gallery.
@property (nonatomic, readonly, copy) NSArray<NSString *> *pictureNames;
/// The mode of its latest picture ("Martin M1"): a decode again by hand may have found another.
@property (nonatomic, readonly, copy) NSString *modeName;
/// The log data are the reception's, kept with it: the radio's valid CAT reading
/// while it was received (0: none, or the radio was retuned during it), and endUTC. Never the
/// radio's reading at the moment of logging later.
@property (nonatomic, readonly) uint64_t catFrequencyHz;
/// Record QSO, once per reception: offered = the Record QSO / Discard QSO form has been shown
/// for it (it is not shown on its own again); logged = recorded (never a second time).
@property (nonatomic, readonly) BOOL offered, logged;
@end

@interface TX500SSTVRecordingStore : NSObject
- (instancetype)initWithDirectory:(NSURL *)directory;
- (instancetype)initWithDirectory:(NSURL *)directory pictureDirectory:(nullable NSURL *)pictures;
/// With the operator's share from the start: what is on disk is trimmed to it, never to the default.
- (instancetype)initWithDirectory:(NSURL *)directory pictureDirectory:(nullable NSURL *)pictures diskShare:(double)share;
/// The size of the disk, for the tests (nil: the disk's own).
@property (class, nonatomic, copy, nullable) unsigned long long (^volumeBytesProvider)(void);
@property (nonatomic, readonly, copy) NSURL *directory;
@property (nonatomic) NSUInteger memoryCount;              // 3 from the radio (and 1 practice); a change applies at once
/// The disk: a share of the disk, 1 % by default; 0 = Off (nothing on disk: no
/// recordings, no pictures, no folder). Setting it sets diskCapBytes; a change applies at once.
@property (nonatomic) double diskShare;
@property (nonatomic) unsigned long long diskCapBytes;     // the share in bytes (or set directly)
/// Never more than a tenth of the free space plus what the recordings already use, all sessions in
/// one cap, so that the disk never fills up again; when that is less than the share,
/// it says so. The kept recordings count within it, and are never removed by it (DEC-16).
@property (nonatomic, readonly) unsigned long long effectiveCapBytes;
@property (nonatomic, readonly) BOOL limitedByFreeSpace;
@property (nonatomic, readonly) unsigned long long volumeBytes;   // the disk it is on (0: not known)
/// The free space on that disk (the tests give their own).
@property (nonatomic, copy, nullable) unsigned long long (^freeBytesProvider)(void);
/// Where the pictures of the receptions are (the gallery folder): their PNGs are counted within the
/// same cap, and go after the audio when room is needed.
@property (nonatomic, copy, nullable) NSURL *pictureDirectory;
/// A copy is only written when the disk keeps this much free besides it (200 MB).
@property (nonatomic) unsigned long long minimumFreeBytes;
/// It says what it does on its own: old recordings removed to stay within the cap (DEC-15), and
/// what could not be done (a copy not written, the list unreadable: DEC-7, DEC-8). What is found
/// or removed while loading is said as soon as onProblem or onRemoved is set.
@property (nonatomic, copy, nullable) void (^onRemoved)(NSUInteger count, unsigned long long bytes);
@property (nonatomic, copy, nullable) void (^onProblem)(NSString *text);
/// Newest first.
@property (nonatomic, readonly, copy) NSArray<TX500SSTVStoredReception *> *receptions;
- (TX500SSTVStoredReception *)addRecording:(TX500SSTVRecording *)recording;
- (TX500SSTVStoredReception *)addRecording:(TX500SSTVRecording *)recording catFrequencyHz:(uint64_t)hz;
/// Keep: never expires. Only marked when a copy on disk exists or could be written; NO (and why)
/// otherwise. With the disk Off it still writes that one copy (the operator's explicit choice).
/// Never for practice (a file the operator opened): NO, and Export recording… is the way.
- (BOOL)setKeep:(BOOL)keep forReception:(TX500SSTVStoredReception *)reception;
- (BOOL)setKeep:(BOOL)keep forReception:(TX500SSTVStoredReception *)reception error:(NSError **)error;
/// The last minutes kept as a recording of their own (Keep on their row): written to disk at once
/// and marked Keep, with no place in memory (its audio is read back from disk). The same minutes
/// (same end and size) give the reception already made, never a second copy. nil, and no row, when
/// the copy cannot be written (and it says why).
- (nullable TX500SSTVStoredReception *)keepCopyOfRecording:(TX500SSTVRecording *)recording catFrequencyHz:(uint64_t)hz
                                                     error:(NSError **)error;
/// The reception from the radio with this audio (the same end and size), or nil.
- (nullable TX500SSTVStoredReception *)receptionFromRadioEndingAt:(nullable NSDate *)end byteSize:(NSUInteger)bytes;
/// Whether a new picture of about this size stays on disk within the share. NO when what the share
/// never removes (kept recordings, those found again in the folder) leaves no room for it: it is not
/// written at all (the share would remove it at once), and that is said once.
- (BOOL)newPictureFitsShare:(unsigned long long)bytes;
/// A picture decoded from a stored reception (the first one, or one more from "Decode again"):
/// it is listed with that reception; no audio is stored again.
- (void)addPictureNamed:(NSString *)name toReception:(TX500SSTVStoredReception *)reception;
- (void)addPictureNamed:(NSString *)name modeName:(nullable NSString *)modeName toReception:(TX500SSTVStoredReception *)reception;
/// The PNG of its latest picture that is still on disk, or nil.
- (nullable NSURL *)latestPictureURLOfReception:(TX500SSTVStoredReception *)reception;
- (void)markOffered:(TX500SSTVStoredReception *)reception;
- (void)markLogged:(TX500SSTVStoredReception *)reception;
- (unsigned long long)diskBytesUsed;
/// What the recordings marked Keep hold on disk, and how many there are.
- (unsigned long long)keptBytes;
- (NSUInteger)keptCount;
/// Its audio, from memory or from disk; nil if it has gone.
- (nullable TX500SSTVRecording *)recordingForReception:(TX500SSTVStoredReception *)reception;
/// Decodes a recording again with other choices, in an engine of its own. The pictures keep where
/// the audio came from (the radio, or a file: practice) and the time it was received; the screen
/// sees that Record QSO is offered only once per reception.
+ (NSArray<TX500SSTVPicture *> *)decodeAgain:(TX500SSTVRecording *)recording
                                       mode:(TX500SSTVModeChoice)mode
                                colourScale:(TX500SSTVColourScale)scale
                              scottieLayout:(TX500SSTVScottieLayout)layout
                                   fitSlant:(BOOL)fitSlant
                                   slantPPM:(double)ppm;
@end

NS_ASSUME_NONNULL_END
