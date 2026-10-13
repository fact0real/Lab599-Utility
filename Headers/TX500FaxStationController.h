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
/// Where «Save to the Fax folder» writes: Application Support/Lab599 Utility/Fax (the tests give their own). It is
/// made at the first save, never before. It is not within «Keep recordings on disk»: the operator saved what is
/// there, so the app never removes or trims it; only the X of a saved chart moves its PNG to the Trash.
@property (nonatomic, copy) NSURL *faxDirectory;
/// Opens the Fax folder for «Show charts in Finder». By default the Finder opens it (NSWorkspace openURL:);
/// the tests give their own, so no Finder window opens.
@property (nonatomic, copy, nullable) void (^revealFolderHandler)(NSURL *folder);
/// Asked before a saved chart's PNG goes to the Trash (the X on its thumbnail): YES moves it. By default a
/// question on the screen, «Move this chart to the Trash?», with Cancel as the default answer; the tests give
/// their own answer.
@property (nonatomic, copy, nullable) BOOL (^confirmMoveToTrash)(NSString *text);
/// How a PNG goes to the Trash: NSFileManager trashItemAtURL: by default (never removed for good); the tests
/// give their own, so nothing reaches the Mac's Trash.
@property (nonatomic, copy, nullable) BOOL (^trashHandler)(NSURL *file, NSError **error);

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
/// «Save to the Fax folder», in the row under the chart: off while no chart is shown.
@property (nonatomic, readonly) NSButton *saveButton;
/// «Show charts in Finder», in the strip's header: it opens faxDirectory. Off, with the tooltip «Nothing
/// saved yet», while that folder does not exist; it never makes the folder.
@property (nonatomic, readonly) NSButton *showChartsButton;
/// What Save and the X did, under the chart's buttons; hidden when nothing.
@property (nonatomic, readonly) NSTextField *folderLabel;

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
/// «Save to the Fax folder»: one click, no dialog. Writes the chart shown as a PNG into faxDirectory (made now
/// if it is not there), under exportName, or with -2, -3… when that name is taken: never over a file. The
/// chart keeps where it went (savedURL), and its thumbnail says so. Nil when nothing was written.
- (nullable NSURL *)saveShownToFaxFolder:(NSError **)error;
/// The X on a thumbnail of the strip (the Delete key on it, and its menu, too). A chart whose PNG is in the
/// folder goes to the Trash, after the question; one with no PNG there only leaves this session's charts,
/// with no question and nothing changed on disk. Shown, the picture shows the empty frame, Export and Save
/// are off, and the line under the buttons says so. YES when it left the strip. A chart of the file open
/// now stays in the chart list until the next file: picked there, it shows again (not saved).
- (BOOL)removeChartFromSession:(TX500FaxChart *)chart;
/// Turns «Show charts in Finder» on or off by whether the Fax folder is there now (the screen shown, a save).
- (void)refreshShowChartsButton;
@end

NS_ASSUME_NONNULL_END
