// SPDX-License-Identifier: GPL-3.0-or-later
// The SSTV screen: receive only, off by default. When it is on it listens to the radio audio
// (shared, never exclusive), paints each picture as it arrives, keeps a gallery, and offers
// "Record QSO" or "Discard QSO" once per reception from the radio: the first time it
// gives a picture (as it arrives, from the last minutes, or decoded again). Later the operator can
// still log it from its row, once. Pictures from a file are practice: never logged.
#import <Cocoa/Cocoa.h>
#import "TX500SSTVEngine.h"
#import "TX500SSTVLogDraft.h"
#import "TX500LogbookManager.h"
#import "TX500SSTVRecordingStore.h"
#import "TX500FaxStationController.h"

NS_ASSUME_NONNULL_BEGIN

/// Was "remember Listen"; no longer written nor read (Listen always starts Off). Kept so an old
/// stored value is known to be ignored.
FOUNDATION_EXPORT NSString *const TX500SSTVEnabledDefaultsKey;

@interface TX500SSTVStationController : NSObject
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) TX500SSTVEngine *engine;          // the radio
@property (nonatomic, readonly) TX500SSTVEngine *practiceEngine;  // files
@property (nonatomic, strong) NSUserDefaults *defaults;            // standard by default
@property (nonatomic, copy) NSURL *galleryDirectory;              // Application Support/Lab599 Utility/SSTV
@property (nonatomic, strong, nullable) TX500LogbookManager *logbook;  // shared by default
/// The radio input. The app gives the station's audio route; nil, or no device: nothing is opened (never the system default input).
@property (nonatomic, copy, nullable) id<TX500SSTVAudioSource> _Nullable (^radioSourceFactory)(void);
/// The radio's frequency by CAT, only when the reading is valid; nil otherwise. Asked when
/// listening starts, at each notice and at each picture's end (each reading talks to the radio).
@property (nonatomic, copy, nullable) NSNumber * _Nullable (^catFrequencyProvider)(void);
@property (nonatomic, copy, nullable) NSString * _Nullable (^myCallsignProvider)(void);
/// The operator's own grid, only when the station profile has one for the logs (SEG-19); nil otherwise.
@property (nonatomic, copy, nullable) NSString * _Nullable (^myGridProvider)(void);
/// Uploading a recorded QSO (the cloud by default), called when the operator ticks «Also upload to
/// Logbook» (upload now). Unticked, the QSO stays pending in the Logbook, and Sync All or Sync
/// Selected there sends it like any other (SEG-9).
@property (nonatomic, copy, nullable) void (^uploadHandler)(TX500LogRecord *record);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
/// Asked before the Mac's own input is opened: YES opens it. By default a question on
/// the screen, with Cancel as the default answer; the tests give their own answer.
@property (nonatomic, copy, nullable) BOOL (^confirmBuiltInInput)(NSString *deviceName);

@property (nonatomic, readonly) BOOL enabled;
/// The fax, files only for now: the second part of this screen (one sidebar entry, «SSTV»).
@property (nonatomic, readonly) TX500FaxStationController *faxController;
@property (nonatomic, readonly) NSSegmentedControl *paneSwitch;
@property (nonatomic, readonly, copy) NSArray<TX500SSTVPicture *> *pictures;   // this session, newest last
@property (nonatomic, readonly, nullable) TX500SSTVPicture *shownPicture;
@property (nonatomic, readonly, nullable) TX500SSTVLogDraft *draft;
/// Every reception's audio, to decode again. Under the gallery folder, "Recordings".
@property (nonatomic, readonly) TX500SSTVRecordingStore *recordings;
/// Nothing piles up without a cap (DEC-4, SEG-4): the pictures kept in memory for the gallery strip
/// (30; older ones stay as their PNG). The PNGs of the radio's pictures count within the disk share,
/// with the recordings; practice ones are never saved on their own (Export… saves one).
@property (nonatomic) NSUInteger galleryInMemory;

// the controls, for the tests
@property (nonatomic, readonly) NSButton *enableSwitch;
@property (nonatomic, readonly) NSTextField *statusLabel, *progressLabel;
@property (nonatomic, readonly) NSPopUpButton *modePopup, *scalePopup, *layoutPopup;
@property (nonatomic, readonly) NSTextField *modeNote, *scaleNote, *layoutNote;
/// The input: the radio's, from the Station screen, by default every session; another
/// one only when the operator chooses it here. And the disk share, always in sight with what is left.
@property (nonatomic, readonly) NSPopUpButton *inputPopup, *diskPopup;
@property (nonatomic, readonly) NSTextField *inputNote, *diskNote, *diskSummaryLabel;
/// The inputs listed after the radio's (@{uid, name, builtIn, virtual}); the app may give its own list.
@property (nonatomic, copy) NSArray<NSDictionary *> *inputDevices;
- (void)refreshInputs;
- (void)refreshDiskSummary;
/// The disk lamp (decided 09-10), right above the picture: green «OK» over 70 % of the share free;
/// yellow «Filling up» at 70 % or less with more than 3 h of audio left; red «Less than 3 h left»;
/// grey «Off». A word always goes with the colour. diskLampState: "ok", "filling", "low" or "off".
@property (nonatomic, readonly, copy) NSString *diskLampState;
+ (NSString *)diskLampTextForShare:(double)share wantBytes:(unsigned long long)want capBytes:(unsigned long long)cap
                         usedBytes:(unsigned long long)used state:(NSString *_Nullable *_Nullable)state;
/// The same, with the kept recordings: they count in what is used and are never removed;
/// when they alone fill the share the lamp is red and says so; with Off it says they are there.
+ (NSString *)diskLampTextForShare:(double)share wantBytes:(unsigned long long)want capBytes:(unsigned long long)cap
                         usedBytes:(unsigned long long)used keptBytes:(unsigned long long)kept keptCount:(NSUInteger)nkept
                             state:(NSString *_Nullable *_Nullable)state;

/// The recent receptions, as in the mockup: a fixed first row for the last minutes of audio (a
/// picture whose header was missed), then each reception, newest first, with its size and status;
/// under it, for the selected row: Decode again…, Keep, Export recording…, Record QSO…, Discard QSO.
@property (nonatomic, readonly) NSTableView *recordingsTable;
@property (nonatomic, readonly) NSButton *decodeAgainButton, *keepCheckbox, *exportRecordingButton, *recordRowButton, *discardRowButton;
/// The choices of Decode again, each with its own note (the same texts as the screen's selectors,
/// following the choice made here).
@property (nonatomic, readonly) NSPopUpButton *againModePopup, *againScalePopup, *againLayoutPopup;
@property (nonatomic, readonly) NSTextField *againModeNote, *againScaleNote, *againLayoutNote;
/// The note under any choice on the screen (the fax part too); nil only for what is not a choice.
- (nullable NSTextField *)noteForPopup:(NSPopUpButton *)popup;
@property (nonatomic, readonly) NSButton *againGoButton;
/// Row 0 is the last minutes; row i is recordings.receptions[i - 1].
- (nullable TX500SSTVStoredReception *)receptionAtRow:(NSInteger)row;
- (NSString *)textForRow:(NSInteger)row column:(NSString *)column;
- (void)reloadRecordings;
@property (nonatomic, readonly) NSImageView *pictureView;            // live: the radio's pictures only
/// A view of its own for a WAV file, Decode again and the gallery (SEG-22): the live
/// view stays the radio's, and a picture can be decoded again while another one arrives.
@property (nonatomic, readonly) NSImageView *reviewPictureView;
@property (nonatomic, readonly) NSTextField *reviewLabel;
@property (nonatomic, readonly) NSButton *reviewExportButton;
@property (nonatomic, readonly, nullable) TX500SSTVPicture *reviewPicture;
@property (nonatomic, readonly) NSView *recordPanel;
@property (nonatomic, readonly) NSTextField *callField, *frequencyField, *bandLabel, *rsvField, *draftProblemLabel, *draftInfoLabel;
/// The notes of the form: the upload switch (they change with it), and Record QSO / Discard QSO.
@property (nonatomic, readonly) NSTextField *uploadNote, *recordNote;
/// The picture the form logs, shown on the form itself (the big one may be newer); draftShowsPicture
/// is NO when it is no longer kept, in memory or on disk (the form says so).
@property (nonatomic, readonly) NSImageView *draftPictureView;
@property (nonatomic, readonly) BOOL draftShowsPicture;
@property (nonatomic, readonly) NSButton *uploadCheckbox, *recordButton, *discardButton, *exportButton;

/// Showing the screen: refreshes it; never opens the audio.
- (void)activate;
/// Turns listening to the radio on or off, for this session only (never remembered). Returns NO
/// (and says why) if the radio input cannot be opened.
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;
/// Decodes a WAV file as practice, in its own engine (the radio keeps listening).
- (BOOL)decodeFileAtURL:(NSURL *)url synchronously:(BOOL)synchronously error:(NSError **)error;
/// The operator's choices from the form, then the logbook (and the cloud, if asked).
- (BOOL)recordQSO:(NSError **)error;
- (void)discardQSO;
- (BOOL)exportPicture:(TX500SSTVPicture *)picture toURL:(NSURL *)url error:(NSError **)error;
- (void)showPicture:(TX500SSTVPicture *)picture;

/// A CAT reading and when it was taken (nil or 0: no valid reading). The screen keeps the last
/// minutes of them, so a picture found later gets the frequency it was received on. The app may
/// give it the readings it takes for itself.
- (void)noteCATFrequency:(nullable NSNumber *)hz atDate:(NSDate *)date;
/// "Decode again" on a stored reception: the new pictures join it (no new audio).
- (NSArray<TX500SSTVPicture *> *)decodeAgainReception:(TX500SSTVStoredReception *)reception mode:(TX500SSTVModeChoice)mode
                                          colourScale:(TX500SSTVColourScale)scale scottieLayout:(TX500SSTVScottieLayout)layout
                                             fitSlant:(BOOL)fitSlant slantPPM:(double)ppm;
/// "Decode again" on the last minutes of the radio audio (a picture whose VIS was missed): with
/// the mode chosen by hand. Each picture found is a reception with its own piece of audio, unless
/// it is one already stored.
- (NSArray<TX500SSTVPicture *> *)decodeLastMinutesWithMode:(TX500SSTVModeChoice)mode colourScale:(TX500SSTVColourScale)scale
                                              scottieLayout:(TX500SSTVScottieLayout)layout fitSlant:(BOOL)fitSlant slantPPM:(double)ppm;
/// "Record QSO…" on a reception's row: the form, with the data kept with the reception. NO (and
/// why) for practice or for a reception already logged.
- (BOOL)beginRecordQSOForReception:(TX500SSTVStoredReception *)reception error:(NSError **)error;
/// Forms waiting their turn (one is shown at a time; none is lost).
@property (nonatomic, readonly) NSUInteger waitingForms;
@end

NS_ASSUME_NONNULL_END
