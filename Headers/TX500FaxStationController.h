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
@property (nonatomic, readonly) NSInteger shownChart;

// the controls, for the tests
@property (nonatomic, readonly) NSPopUpButton *deviationPopup, *lpmPopup, *iocPopup, *widthPopup, *lineStartPopup, *chartPopup;
@property (nonatomic, readonly) NSTextField *deviationNote, *lpmNote, *iocNote, *widthNote, *lineStartNote;
@property (nonatomic, readonly) NSTextField *infoLabel, *noticeLabel, *practiceLabel, *marginLabel;
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
/// Moves the shown chart's margin, in points (the slider).
- (void)setMarginPoints:(double)points;
- (BOOL)exportShownToURL:(NSURL *)url error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
