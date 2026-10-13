// SPDX-License-Identifier: GPL-3.0-or-later
// The fax tab of the SSTV screen, files only for now: open a WAV, see the chart, move its margin,
// decode it again with other choices, export it. It does not listen to the radio yet. Receive only:
// no audio output, no CAT, no PTT. A chart is no contact: no Record QSO, and nothing is ever logged.
#import <Cocoa/Cocoa.h>
#import "TX500FaxEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500FaxStationController : NSObject
@property (nonatomic, readonly) NSView *view;
@property (nonatomic, readonly) TX500FaxEngine *engine;
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
/// The file decoded last (Decode again uses it again, with the choices on screen).
@property (nonatomic, readonly, copy, nullable) NSURL *fileURL;
/// The chart shown: one of the open file's, or one of an earlier file's from the strip (nil for none).
@property (nonatomic, readonly, nullable) TX500FaxChart *displayedChart;
/// Its place among the open file's charts, as in the chart list (-1 for an earlier file's chart, or none).
@property (nonatomic, readonly) NSInteger shownChart;
/// Nothing piles up without a cap: this session's charts kept for the strip, from every file opened
/// (12; the oldest leave first, at once when it is lowered). A chart can take 7 MB in memory (1810 x 4000 greys).
@property (nonatomic) NSUInteger galleryInMemory;
/// This session's charts in the strip, the oldest first: the strip's own references, never the
/// engine's places (an earlier file's charts are no longer in the engine).
@property (nonatomic, readonly, copy) NSArray<TX500FaxChart *> *sessionCharts;

// the controls, for the tests
@property (nonatomic, readonly) NSPopUpButton *deviationPopup, *lpmPopup, *iocPopup, *widthPopup, *lineStartPopup, *chartPopup;
@property (nonatomic, readonly) NSTextField *deviationNote, *lpmNote, *iocNote, *widthNote, *lineStartNote;
@property (nonatomic, readonly) NSTextField *infoLabel, *noticeLabel, *practiceLabel, *marginLabel;
/// Under the margin, for a chart of an earlier file: its margin cannot be moved; hidden otherwise.
@property (nonatomic, readonly) NSTextField *marginNote;
/// The strip of this session's charts: one thumbnail button each, in the order of sessionCharts.
@property (nonatomic, readonly) NSStackView *sessionStrip;
/// What could not be done (a file refused, an export that failed), on its own line, in red; hidden when nothing.
@property (nonatomic, readonly) NSTextField *errorLabel;
@property (nonatomic, readonly) NSSlider *marginSlider;
@property (nonatomic, readonly) NSImageView *pictureView;
@property (nonatomic, readonly) NSButton *openButton, *againButton, *exportButton;

/// The note under a choice, with its Good for / Not good for (nil for the list of charts, which is
/// not a choice: it shows one of the charts the file gave).
- (nullable NSTextField *)noteForPopup:(NSPopUpButton *)popup;
/// Decodes a WAV with the choices on screen (as Open WAV… does, without the panel).
- (BOOL)decodeFileAtURL:(NSURL *)url error:(NSError **)error;
/// What Open WAV… does once the file is chosen: decodes it, or says on the error line why not (the
/// chart shown before stays, and can still be exported).
- (BOOL)openFileAtURL:(NSURL *)url;
/// Decode again: the same file, the choices on screen now.
- (BOOL)decodeAgain:(NSError **)error;
/// Moves the shown chart's margin, in points (the slider): only on a chart of the file open now (an
/// earlier file's samples are gone); no other chart is ever touched.
- (void)setMarginPoints:(double)points;
/// Writes the chart shown, whichever file it came from.
- (BOOL)exportShownToURL:(NSURL *)url error:(NSError **)error;
/// The name Export… proposes: the file the chart shown came from, and its number there.
@property (nonatomic, readonly, copy) NSString *exportName;
@end

NS_ASSUME_NONNULL_END
