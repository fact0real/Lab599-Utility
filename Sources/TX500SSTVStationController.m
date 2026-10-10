// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500SSTVStationController.h"
#import "TX500SSTVOptionNotes.h"
#import "TX500CloudSyncEngine.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString *const TX500SSTVEnabledDefaultsKey = @"TX500SSTVEnabled";
static NSString *const TX500SSTVModeDefaultsKey = @"TX500SSTVMode";
static NSString *const TX500SSTVScaleDefaultsKey = @"TX500SSTVColourScale";
static NSString *const TX500SSTVLayoutDefaultsKey = @"TX500SSTVScottieLayout";
static NSString *const TX500SSTVDiskShareDefaultsKey = @"TX500SSTVDiskShare";   // the operator's choice, kept (it opens nothing)

@interface TX500SSTVStationController () <NSMenuDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, readwrite) NSView *view;
@property (nonatomic, readwrite) TX500SSTVEngine *engine, *practiceEngine;
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, strong) NSMutableArray<TX500SSTVPicture *> *gallery;
@property (nonatomic, readwrite, nullable) TX500SSTVPicture *shownPicture;
@property (nonatomic, readwrite, nullable) TX500SSTVLogDraft *draft;
@property (nonatomic, readwrite) NSButton *enableSwitch, *uploadCheckbox, *recordButton, *discardButton, *exportButton, *openButton;
@property (nonatomic, readwrite) NSTextField *statusLabel, *modeNote, *scaleNote, *layoutNote, *progressLabel;
@property (nonatomic, readwrite) NSPopUpButton *modePopup, *scalePopup, *layoutPopup, *inputPopup, *diskPopup;
@property (nonatomic, readwrite) NSTextField *inputNote, *diskNote, *diskSummaryLabel;
@property (nonatomic, readwrite) NSImageView *pictureView, *draftPictureView, *reviewPictureView;
@property (nonatomic, readwrite) NSTextField *reviewLabel;
@property (nonatomic, readwrite) NSButton *reviewExportButton;
@property (nonatomic, readwrite, nullable) TX500SSTVPicture *reviewPicture;
@property (nonatomic, readwrite) NSView *recordPanel;
@property (nonatomic, readwrite) NSTextField *callField, *frequencyField, *bandLabel, *rsvField, *draftProblemLabel, *draftInfoLabel;
@property (nonatomic, readwrite) NSTextField *uploadNote, *recordNote;
@property (nonatomic, strong) NSStackView *galleryStack;
@property (nonatomic, strong, nullable) TX500SSTVRecordingStore *store;
@property (nonatomic, strong) NSMutableArray<TX500SSTVLogDraft *> *waitingDrafts;   // one form at a time; none lost
@property (nonatomic, strong) NSMutableArray<NSArray *> *catReadings;            // @[date, hz], the last minutes
@property (nonatomic) NSInteger serial;                                          // the gallery buttons' tags
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, TX500SSTVPicture *> *bySerial;
@property (nonatomic) BOOL inputDevicesGiven;                                     // the app or a test gave the list
@property (nonatomic, readwrite) NSTableView *recordingsTable;
@property (nonatomic, readwrite) NSButton *decodeAgainButton, *keepCheckbox, *exportRecordingButton, *recordRowButton, *discardRowButton, *againGoButton;
@property (nonatomic, readwrite) NSPopUpButton *againModePopup, *againScalePopup, *againLayoutPopup;
@property (nonatomic, readwrite) NSTextField *againModeNote, *againScaleNote, *againLayoutNote;
@property (nonatomic, strong) NSView *againPanel;
@property (nonatomic, readwrite, copy) NSString *diskLampState;
@property (nonatomic, readwrite) TX500FaxStationController *faxController;
@property (nonatomic, readwrite) NSSegmentedControl *paneSwitch;
@property (nonatomic) BOOL choiceWaiting;                                       // a new choice waits for the next picture
@property (nonatomic, strong) NSView *sstvPane;
@end

@implementation TX500SSTVStationController

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = NSUserDefaults.standardUserDefaults;
        NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        _galleryDirectory = [[support URLByAppendingPathComponent:@"Lab599 Utility" isDirectory:YES]
                             URLByAppendingPathComponent:@"SSTV" isDirectory:YES];
        _gallery = [NSMutableArray array];
        _waitingDrafts = [NSMutableArray array];
        _bySerial = [NSMutableDictionary dictionary];
        _galleryInMemory = 30;
        _inputDevices = @[];          // asked of the system only when the operator opens the list (menuNeedsUpdate:)
        _catReadings = [NSMutableArray array];
        _engine = [TX500SSTVEngine new];
        _practiceEngine = [TX500SSTVEngine new];
        [self wireEngine:_engine];
        [self wireEngine:_practiceEngine];
        [self buildView];
    }
    return self;
}

- (NSArray<TX500SSTVPicture *> *)pictures { return [self.gallery copy]; }

// the disk share chosen and kept, or the default when none is kept or it is not one of the list: the
// selector and the store always say the same (N2-importants-nous-9)
- (NSInteger)savedDiskIndex {
    NSInteger d = [self.defaults objectForKey:TX500SSTVDiskShareDefaultsKey] ? [self.defaults integerForKey:TX500SSTVDiskShareDefaultsKey]
                                                                             : TX500SSTVOptionNotes.defaultDiskIndex;
    return (d >= 0 && d < (NSInteger)TX500SSTVOptionNotes.diskShares.count) ? d : TX500SSTVOptionNotes.defaultDiskIndex;
}

// the choices kept in these defaults show on the selectors (they were built before these were given)
- (void)setDefaults:(NSUserDefaults *)defaults {
    _defaults = defaults;
    if (!self.modePopup) return;
    NSInteger m = [defaults integerForKey:TX500SSTVModeDefaultsKey], c = [defaults integerForKey:TX500SSTVScaleDefaultsKey],
              l = [defaults integerForKey:TX500SSTVLayoutDefaultsKey];
    NSInteger d = [self savedDiskIndex];
    [self.modePopup selectItemAtIndex:(m >= 0 && m < self.modePopup.numberOfItems) ? m : 0];
    [self.scalePopup selectItemAtIndex:(c >= 0 && c < self.scalePopup.numberOfItems) ? c : 0];
    [self.layoutPopup selectItemAtIndex:(l >= 0 && l < self.layoutPopup.numberOfItems) ? l : 0];
    [self.diskPopup selectItemAtIndex:(d >= 0 && d < self.diskPopup.numberOfItems) ? d : TX500SSTVOptionNotes.defaultDiskIndex];
    [self refreshNotes];
}

- (TX500SSTVRecordingStore *)recordings {
    if (!self.store) {
        // the operator's share from the start: the store never trims to the default first (N-memoria-disc-1)
        NSInteger di = [self savedDiskIndex];
        TX500SSTVRecordingStore *st = [[TX500SSTVRecordingStore alloc] initWithDirectory:
                                       [self.galleryDirectory URLByAppendingPathComponent:@"Recordings" isDirectory:YES]
                                                                         pictureDirectory:self.galleryDirectory
                                                                                diskShare:TX500SSTVOptionNotes.diskShares[(NSUInteger)di].doubleValue];
        __weak TX500SSTVStationController *weakSelf = self;
        st.onProblem = ^(NSString *text) { [weakSelf log:text]; weakSelf.progressLabel.stringValue = text; };
        st.onRemoved = ^(NSUInteger count, unsigned long long bytes) {
            NSString *t = [NSString stringWithFormat:@"Removed %lu old recording%@ (%.1f MB) to stay within the disk space chosen.",
                           (unsigned long)count, count == 1 ? @"" : @"s", bytes / 1e6];
            [weakSelf log:t];
        };
        self.store = st;
    }
    return self.store;
}

- (void)log:(NSString *)line { if (self.logHandler) self.logHandler([@"[SSTV] " stringByAppendingString:line]); }

#pragma mark - the radio's frequency, kept with its time

- (void)noteCATFrequency:(nullable NSNumber *)hz atDate:(NSDate *)date {
    [self.catReadings addObject:@[date, @(hz.unsignedLongLongValue)]];
    NSTimeInterval keep = self.engine.ringSeconds + 300.0;
    while (self.catReadings.count && [date timeIntervalSinceDate:self.catReadings.firstObject[0]] > keep)
        [self.catReadings removeObjectAtIndex:0];
}

- (nullable NSNumber *)readCATNow {
    NSNumber *hz = self.catFrequencyProvider ? self.catFrequencyProvider() : nil;
    if (self.catFrequencyProvider) [self noteCATFrequency:hz atDate:[NSDate date]];
    return hz;
}

// The frequency a picture was received on: the valid readings taken during it (and the one taken
// as it ended, when it has just arrived), if they agree; with none during it, the last one before
// and the first one after, if they agree and are no further from it than the last minutes the
// receiver keeps. Otherwise 0: the operator enters it. Readings without a valid answer say
// nothing either way.
- (uint64_t)catFrequencyFrom:(NSDate *)start to:(NSDate *)end endReading:(uint64_t)atEnd {
    uint64_t during = atEnd, before = 0, after = 0;
    NSDate *beforeAt = nil, *afterAt = nil;
    NSTimeInterval span = self.engine.ringSeconds;
    for (NSArray *r in self.catReadings) {
        NSDate *t = r[0];
        uint64_t hz = [r[1] unsignedLongLongValue];
        if (!hz) continue;
        NSTimeInterval fromStart = [t timeIntervalSinceDate:start], fromEnd = [t timeIntervalSinceDate:end];
        if (fromStart >= -2.0 && fromEnd <= 1.0) {
            if (during && during != hz) return 0;                        // retuned during the picture
            during = hz;
        } else if (fromStart < -2.0 && -fromStart <= span && (!beforeAt || [t compare:beforeAt] == NSOrderedDescending)) {
            before = hz; beforeAt = t;                                   // the last one before
        } else if (fromEnd > 1.0 && fromEnd <= span && (!afterAt || [t compare:afterAt] == NSOrderedAscending)) {
            after = hz; afterAt = t;                                     // the first one after
        }
    }
    if (during) return during;
    return (before && before == after) ? before : 0;
}

static NSDate *SSTVPictureStart(TX500SSTVPicture *p) { return p.startUTC ?: p.endUTC; }



#pragma mark - view

static NSTextField *SSTVNote(void) {
    NSTextField *f = [NSTextField wrappingLabelWithString:@""];
    f.font = [NSFont systemFontOfSize:11];
    f.textColor = NSColor.secondaryLabelColor;
    f.preferredMaxLayoutWidth = 520;
    return f;
}

static NSStackView *SSTVRow(NSArray<NSView *> *views) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = NSLayoutAttributeCenterY;
    s.spacing = 8;
    return s;
}

static NSStackView *SSTVColumn(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = spacing;
    return s;
}

- (NSPopUpButton *)popupWithTitles:(NSArray<NSString *> *)titles selected:(NSInteger)sel action:(SEL)action {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [p addItemsWithTitles:titles];
    [p selectItemAtIndex:(sel >= 0 && sel < (NSInteger)titles.count) ? sel : 0];
    p.target = self; p.action = action;
    return p;
}

- (void)buildView {
    self.enableSwitch = [NSButton checkboxWithTitle:@"Listen to the radio audio" target:self action:@selector(enableToggled:)];
    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    NSTextField *intro = SSTVNote();
    intro.stringValue = @"Receive only. Off by default. When on, it shares the radio audio input with the other screens "
                        @"and never transmits. Pictures from the radio can be logged by hand after each one; "
                        @"pictures from a WAV file are practice and are never logged.";

    self.modePopup = [self popupWithTitles:TX500SSTVOptionNotes.modeTitles
                                  selected:[self.defaults integerForKey:TX500SSTVModeDefaultsKey] action:@selector(optionChanged:)];
    self.scalePopup = [self popupWithTitles:TX500SSTVOptionNotes.colourScaleTitles
                                   selected:[self.defaults integerForKey:TX500SSTVScaleDefaultsKey] action:@selector(optionChanged:)];
    self.layoutPopup = [self popupWithTitles:TX500SSTVOptionNotes.scottieLayoutTitles
                                    selected:[self.defaults integerForKey:TX500SSTVLayoutDefaultsKey] action:@selector(optionChanged:)];
    self.modeNote = SSTVNote(); self.scaleNote = SSTVNote(); self.layoutNote = SSTVNote();
    self.inputPopup = [self popupWithTitles:@[@"Radio receive input (from the Station screen)"] selected:0 action:@selector(inputChanged:)];
    self.inputPopup.menu.delegate = self;
    self.inputNote = SSTVNote();
    self.diskPopup = [self popupWithTitles:TX500SSTVOptionNotes.diskTitles selected:[self savedDiskIndex] action:@selector(diskChanged:)];
    self.diskNote = SSTVNote();
    self.diskSummaryLabel = [NSTextField labelWithString:@""];
    self.diskSummaryLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightSemibold];
    self.diskSummaryLabel.drawsBackground = YES;
    [self.diskSummaryLabel.widthAnchor constraintGreaterThanOrEqualToConstant:480].active = YES;

    self.pictureView = [NSImageView imageViewWithImage:[[NSImage alloc] initWithSize:NSMakeSize(320, 256)]];
    self.pictureView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.pictureView.imageFrameStyle = NSImageFrameGrayBezel;
    [self.pictureView.widthAnchor constraintEqualToConstant:480].active = YES;
    [self.pictureView.heightAnchor constraintEqualToConstant:384].active = YES;
    self.progressLabel = [NSTextField labelWithString:@"No picture yet."];
    self.progressLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    // a view of its own for a WAV and for Decode again, so the live one stays the radio's and a picture
    // can be decoded again while another arrives (SEG-22)
    self.reviewPictureView = [NSImageView imageViewWithImage:[[NSImage alloc] initWithSize:NSMakeSize(320, 256)]];
    self.reviewPictureView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.reviewPictureView.imageFrameStyle = NSImageFrameGrayBezel;
    [self.reviewPictureView.widthAnchor constraintEqualToConstant:320].active = YES;
    [self.reviewPictureView.heightAnchor constraintEqualToConstant:256].active = YES;
    self.reviewLabel = [NSTextField labelWithString:@"A WAV file, Decode again and the gallery show here; the live picture above is the radio's."];
    self.reviewLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.reviewExportButton = [NSButton buttonWithTitle:@"Export…" target:self action:@selector(exportReview:)];
    self.reviewExportButton.enabled = NO;

    self.openButton = [NSButton buttonWithTitle:@"Open WAV…" target:self action:@selector(openFile:)];
    self.exportButton = [NSButton buttonWithTitle:@"Export…" target:self action:@selector(exportShown:)];
    self.exportButton.enabled = NO;

    // the assisted log, shown after a picture from the radio
    self.draftInfoLabel = [NSTextField labelWithString:@""];
    self.callField = [NSTextField textFieldWithString:@""]; self.callField.placeholderString = @"Callsign (required)";
    self.frequencyField = [NSTextField textFieldWithString:@""]; self.frequencyField.placeholderString = @"MHz (required)";
    self.frequencyField.target = self; self.frequencyField.action = @selector(frequencyEdited:);
    self.bandLabel = [NSTextField labelWithString:@"Band: —"];
    self.rsvField = [NSTextField textFieldWithString:@""]; self.rsvField.placeholderString = @"RSV";
    for (NSTextField *f in @[self.callField, self.frequencyField, self.rsvField]) [f.widthAnchor constraintEqualToConstant:120].active = YES;
    self.uploadCheckbox = [NSButton checkboxWithTitle:@"Also upload to Logbook" target:self action:@selector(uploadToggled:)];   // (SEG-9)
    self.uploadCheckbox.state = NSControlStateValueOff;
    self.uploadNote = SSTVNote();
    self.uploadNote.stringValue = [TX500SSTVOptionNotes noteForUploadNow:NO];
    self.recordNote = SSTVNote();
    self.recordNote.stringValue = [TX500SSTVOptionNotes noteForRecordOrDiscard];
    self.recordButton = [NSButton buttonWithTitle:@"Record QSO" target:self action:@selector(recordClicked:)];
    self.discardButton = [NSButton buttonWithTitle:@"Discard QSO" target:self action:@selector(discardClicked:)];
    self.draftProblemLabel = SSTVNote();
    // the form shows the picture it logs: the big picture above may already be a newer one (N-captura-8)
    self.draftPictureView = [NSImageView imageViewWithImage:[[NSImage alloc] initWithSize:NSMakeSize(160, 128)]];
    self.draftPictureView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.draftPictureView.imageFrameStyle = NSImageFrameGrayBezel;
    [self.draftPictureView.widthAnchor constraintEqualToConstant:160].active = YES;
    [self.draftPictureView.heightAnchor constraintEqualToConstant:128].active = YES;
    self.draftInfoLabel.preferredMaxLayoutWidth = 600;
    self.draftInfoLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.draftInfoLabel.maximumNumberOfLines = 3;
    NSStackView *form = SSTVColumn(@[self.draftInfoLabel,
                                     SSTVRow(@[self.callField, self.frequencyField, self.bandLabel, self.rsvField]),
                                     SSTVRow(@[self.uploadCheckbox, self.recordButton, self.discardButton]),
                                     self.uploadNote, self.recordNote,
                                     self.draftProblemLabel], 6);
    NSStackView *panel = SSTVRow(@[self.draftPictureView, form]);
    panel.alignment = NSLayoutAttributeTop;
    self.recordPanel = panel;
    self.recordPanel.hidden = YES;

    self.galleryStack = SSTVRow(@[]);
    NSScrollView *galleryScroll = [NSScrollView new];
    galleryScroll.hasHorizontalScroller = YES;
    galleryScroll.documentView = self.galleryStack;
    [galleryScroll.heightAnchor constraintEqualToConstant:80].active = YES;
    [galleryScroll.widthAnchor constraintEqualToConstant:520].active = YES;

    // the recent receptions, and what can be done with the selected one
    self.recordingsTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
    for (NSArray *c in @[@[@"ended", @"Ended (UTC)", @130], @[@"mode", @"Mode", @190], @[@"from", @"From", @50],
                         @[@"pictures", @"Pictures", @55], @[@"audio", @"Audio", @70], @[@"keep", @"Keep", @40], @[@"status", @"Status", @230]]) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1]; col.width = [c[2] doubleValue];
        [self.recordingsTable addTableColumn:col];
    }
    self.recordingsTable.dataSource = self;
    self.recordingsTable.delegate = self;
    NSScrollView *recScroll = [NSScrollView new];
    recScroll.documentView = self.recordingsTable;
    recScroll.hasVerticalScroller = YES;
    [recScroll.heightAnchor constraintEqualToConstant:140].active = YES;
    [recScroll.widthAnchor constraintEqualToConstant:780].active = YES;
    self.decodeAgainButton = [NSButton buttonWithTitle:@"Decode again…" target:self action:@selector(toggleAgainPanel:)];
    self.keepCheckbox = [NSButton checkboxWithTitle:@"Keep (never expires)" target:self action:@selector(keepClicked:)];
    self.exportRecordingButton = [NSButton buttonWithTitle:@"Export recording…" target:self action:@selector(exportRecordingClicked:)];
    self.recordRowButton = [NSButton buttonWithTitle:@"Record QSO…" target:self action:@selector(recordRowClicked:)];
    self.discardRowButton = [NSButton buttonWithTitle:@"Discard QSO" target:self action:@selector(discardRowClicked:)];
    // each choice of Decode again with its own Good for / Not good for, as the screen's (N-proves-afirmacions-1)
    self.againModePopup = [self popupWithTitles:TX500SSTVOptionNotes.modeTitles selected:0 action:@selector(againOptionChanged:)];
    self.againScalePopup = [self popupWithTitles:TX500SSTVOptionNotes.colourScaleTitles selected:0 action:@selector(againOptionChanged:)];
    self.againLayoutPopup = [self popupWithTitles:TX500SSTVOptionNotes.scottieLayoutTitles selected:0 action:@selector(againOptionChanged:)];
    self.againModeNote = SSTVNote(); self.againScaleNote = SSTVNote(); self.againLayoutNote = SSTVNote();
    self.againGoButton = [NSButton buttonWithTitle:@"Decode again" target:self action:@selector(againGoClicked:)];
    self.againPanel = SSTVColumn(@[
        [NSTextField labelWithString:@"Decode again from the recording: the same audio, other choices; the new picture joins the same recording"],
        SSTVRow(@[[NSTextField labelWithString:@"Mode:"], self.againModePopup]), self.againModeNote,
        SSTVRow(@[[NSTextField labelWithString:@"Colour scale:"], self.againScalePopup]), self.againScaleNote,
        SSTVRow(@[[NSTextField labelWithString:@"Scottie timing:"], self.againLayoutPopup]), self.againLayoutNote,
        self.againGoButton], 4);
    self.againPanel.hidden = YES;

    NSStackView *root = SSTVColumn(@[
        SSTVRow(@[self.enableSwitch, self.statusLabel]),
        SSTVRow(@[[NSTextField labelWithString:@"Input:"], self.inputPopup]), self.inputNote, intro,
        SSTVRow(@[[NSTextField labelWithString:@"Mode:"], self.modePopup]), self.modeNote,
        SSTVRow(@[[NSTextField labelWithString:@"Colour scale:"], self.scalePopup]), self.scaleNote,
        SSTVRow(@[[NSTextField labelWithString:@"Scottie timing:"], self.layoutPopup]), self.layoutNote,
        self.diskSummaryLabel, self.pictureView, self.progressLabel,
        SSTVRow(@[self.exportButton]),
        self.recordPanel,
        [NSTextField labelWithString:@"Files and Decode again (a view of their own: the picture above is only the radio's):"],
        self.reviewPictureView, self.reviewLabel,
        SSTVRow(@[self.openButton, self.reviewExportButton]),
        [NSTextField labelWithString:@"Gallery (the last pictures; those from the radio are also kept as PNGs, within the disk share):"], galleryScroll,
        [NSTextField labelWithString:@"Recent receptions (the last ones in memory; the recent ones also on disk, within the share below):"],
        recScroll,
        SSTVRow(@[self.decodeAgainButton, self.keepCheckbox, self.exportRecordingButton, self.recordRowButton, self.discardRowButton]),
        self.againPanel,
        SSTVRow(@[[NSTextField labelWithString:@"Keep recordings on disk:"], self.diskPopup]), self.diskNote
    ], 8);
    // the fax, files only for now, on the same screen: a switch shows one part or the other
    self.sstvPane = root;
    self.faxController = [TX500FaxStationController new];
    // the fax's lines go to the app's log as the SSTV ones do (N2-fax-app-16)
    __weak TX500SSTVStationController *weakSelfFax = self;
    self.faxController.logHandler = ^(NSString *message) { if (weakSelfFax.logHandler) weakSelfFax.logHandler(message); };
    self.faxController.view.hidden = YES;
    self.paneSwitch = [NSSegmentedControl segmentedControlWithLabels:@[@"SSTV", @"Fax (files only for now)"]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(paneChosen:)];
    self.paneSwitch.selectedSegment = 0;
    NSStackView *outer = SSTVColumn(@[self.paneSwitch, root, self.faxController.view], 10);
    outer.translatesAutoresizingMaskIntoConstraints = NO;
    self.view = outer;
    [self refreshInputs];
    [self refreshNotes];
    [self updateRowButtons];
    [self refreshStatus];
}

- (void)refreshNotes {
    self.modeNote.stringValue = [TX500SSTVOptionNotes noteForMode:(TX500SSTVModeChoice)self.modePopup.indexOfSelectedItem];
    self.scaleNote.stringValue = [TX500SSTVOptionNotes noteForColourScale:(TX500SSTVColourScale)self.scalePopup.indexOfSelectedItem];
    self.layoutNote.stringValue = [TX500SSTVOptionNotes noteForScottieLayout:(TX500SSTVScottieLayout)self.layoutPopup.indexOfSelectedItem];
    self.inputNote.stringValue = [TX500SSTVOptionNotes noteForInputKind:[self kindOfInputAtIndex:self.inputPopup.indexOfSelectedItem]];
    self.diskNote.stringValue = [TX500SSTVOptionNotes noteForDiskShareAtIndex:self.diskPopup.indexOfSelectedItem];
    self.againModeNote.stringValue = [TX500SSTVOptionNotes noteForMode:(TX500SSTVModeChoice)self.againModePopup.indexOfSelectedItem];
    self.againScaleNote.stringValue = [TX500SSTVOptionNotes noteForColourScale:(TX500SSTVColourScale)self.againScalePopup.indexOfSelectedItem];
    self.againLayoutNote.stringValue = [TX500SSTVOptionNotes noteForScottieLayout:(TX500SSTVScottieLayout)self.againLayoutPopup.indexOfSelectedItem];
}

- (void)againOptionChanged:(id)sender { (void)sender; [self refreshNotes]; }

- (nullable NSTextField *)noteForPopup:(NSPopUpButton *)popup {
    NSArray *pairs = @[@[self.modePopup, self.modeNote], @[self.scalePopup, self.scaleNote], @[self.layoutPopup, self.layoutNote],
                       @[self.inputPopup, self.inputNote], @[self.diskPopup, self.diskNote], @[self.againModePopup, self.againModeNote],
                       @[self.againScalePopup, self.againScaleNote], @[self.againLayoutPopup, self.againLayoutNote]];
    for (NSArray *pr in pairs) if (pr[0] == popup) return pr[1];
    return [self.faxController noteForPopup:popup];
}

#pragma mark - the input and the disk

- (TX500SSTVInputKind)kindOfInputAtIndex:(NSInteger)i {
    if (i <= 0 || i > (NSInteger)self.inputDevices.count) return TX500SSTVInputRadio;
    NSDictionary *d = self.inputDevices[(NSUInteger)i - 1];
    return [d[@"builtIn"] boolValue] ? TX500SSTVInputBuiltIn : [d[@"virtual"] boolValue] ? TX500SSTVInputVirtual : TX500SSTVInputOther;
}

// The Mac's inputs are asked for only when the operator opens the list: even listing them makes the
// audio system check the microphone permission, and nothing of that happens on its own.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.inputPopup.menu || self.inputDevicesGiven) return;
    _inputDevices = [TX500SSTVRadioSource inputDevices];
    [self refreshInputs];
}

- (void)setInputDevices:(NSArray<NSDictionary *> *)devices {
    _inputDevices = [devices copy];
    self.inputDevicesGiven = YES;
}

// the radio's input first; then every input of this Mac, said for what it is; the choice stays
- (void)refreshInputs {
    NSInteger was = self.inputPopup.indexOfSelectedItem;
    NSString *wasUID = was > 0 ? self.inputPopup.selectedItem.representedObject : nil;
    [self.inputPopup removeAllItems];
    [self.inputPopup addItemWithTitle:@"Radio receive input (from the Station screen)"];
    // every device its own item, even two with the same name (addItemWithTitle: would drop the second,
    // and the list would no longer match the devices: N-seguretat-11); the second gets a number
    NSCountedSet *seen = [NSCountedSet set];
    for (NSDictionary *d in self.inputDevices) {
        NSString *t = [NSString stringWithFormat:@"%@%@", d[@"name"],
                       [d[@"builtIn"] boolValue] ? @" (built in)" : [d[@"virtual"] boolValue] ? @" (virtual)" : @""];
        [seen addObject:t];
        if ([seen countForObject:t] > 1) t = [NSString stringWithFormat:@"%@ (%lu)", t, (unsigned long)[seen countForObject:t]];
        NSMenuItem *item = [self.inputPopup.menu addItemWithTitle:t action:NULL keyEquivalent:@""];
        item.representedObject = d[@"uid"];
    }
    NSInteger keep = 0;
    for (NSInteger i = 1; wasUID && i < self.inputPopup.numberOfItems; i++)
        if ([[self.inputPopup itemAtIndex:i].representedObject isEqual:wasUID]) keep = i;
    [self.inputPopup selectItemAtIndex:keep];
}

- (nullable id<TX500SSTVAudioSource>)chosenInput {
    NSInteger i = self.inputPopup.indexOfSelectedItem;
    if (i > 0 && i <= (NSInteger)self.inputDevices.count)
        return [[TX500SSTVRadioSource alloc] initWithDeviceUID:self.inputDevices[(NSUInteger)i - 1][@"uid"]];
    return self.radioSourceFactory ? self.radioSourceFactory() : [[TX500SSTVRadioSource alloc] initWithDeviceUID:nil];
}

- (void)inputChanged:(id)sender {
    (void)sender;
    [self refreshNotes];
    if (self.enabled) {                                         // another input is a new listening: it opens that one
        [self setEnabled:NO error:nil];
        [self setEnabled:YES error:nil];
    }
}

- (void)diskChanged:(id)sender {
    (void)sender;
    NSInteger i = self.diskPopup.indexOfSelectedItem;
    [self.defaults setInteger:i forKey:TX500SSTVDiskShareDefaultsKey];
    self.recordings.diskShare = TX500SSTVOptionNotes.diskShares[(NSUInteger)i].doubleValue;
    [self refreshNotes];
    [self reloadRecordings];
}

// MB with thousands, or GB from 10 GB on
static NSString *SSTVSize(double bytes) {
    double mb = bytes / 1e6;
    if (mb >= 10000.0) return [NSString stringWithFormat:@"%.1f GB", mb / 1000.0];
    NSNumberFormatter *f = [NSNumberFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    f.maximumFractionDigits = 0;
    return [NSString stringWithFormat:@"%@ MB", [f stringFromNumber:@(llround(mb))]];
}

+ (NSString *)diskLampTextForShare:(double)share wantBytes:(unsigned long long)want capBytes:(unsigned long long)cap
                         usedBytes:(unsigned long long)used state:(NSString **)state {
    return [self diskLampTextForShare:share wantBytes:want capBytes:cap usedBytes:used keptBytes:0 keptCount:0 state:state];
}

// The kept recordings count in what is used, as they are on disk (DEC-16); the share
// never removes them, so when they alone fill it the lamp is red and says so. With Off, what is kept
// is the operator's own choice, one recording at a time, and the lamp says it is there (DEC-17).
+ (NSString *)diskLampTextForShare:(double)share wantBytes:(unsigned long long)want capBytes:(unsigned long long)cap
                         usedBytes:(unsigned long long)used keptBytes:(unsigned long long)kept keptCount:(NSUInteger)nkept
                             state:(NSString **)state {
    NSString *keptText = nkept ? [NSString stringWithFormat:@"%lu kept recording%@, %@", (unsigned long)nkept, nkept == 1 ? @"" : @"s",
                                  SSTVSize((double)kept)] : nil;
    if (share <= 0) {
        if (state) *state = @"off";
        return keptText ? [NSString stringWithFormat:@"Off · only what you keep is on disk: %@", keptText] : @"Off · nothing is saved on disk";
    }
    if (cap > 0 && kept >= cap) {
        if (state) *state = @"low";
        return [NSString stringWithFormat:@"Kept recordings fill the share · Recordings %g %% of disk (%@) · %@, never removed: "
                                          "new recordings and pictures stay in memory only (free some Keep, or choose a bigger share)",
                share * 100.0, SSTVSize(want), keptText ?: SSTVSize((double)kept)];
    }
    double freeB = cap > used ? (double)(cap - used) : 0.0, hours = freeB / 86.4e6;
    long pct = cap > 0 ? lround(100.0 * freeB / (double)cap) : 0;
    // the thresholds on the share free as it is, not as it is shown rounded: 70.4 % is over 70 % (N-memoria-disc-9)
    NSString *s = hours < 3.0 ? @"low" : (cap > 0 && freeB > 0.70 * (double)cap) ? @"ok" : @"filling";
    NSString *word = [s isEqualToString:@"low"] ? @"Less than 3 h left" : [s isEqualToString:@"ok"] ? @"OK" : @"Filling up";
    if (state) *state = s;
    NSString *limited = cap < want ? [NSString stringWithFormat:@", limited to %@ (a tenth of the free space plus the recordings)", SSTVSize(cap)] : @"";
    return [NSString stringWithFormat:@"%@ · Recordings %g %% of disk (%@)%@ · %@ free (%ld %%) · about %.0f h left%@",
            word, share * 100.0, SSTVSize(want), limited, SSTVSize(freeB), pct, floor(hours),
            keptText ? [NSString stringWithFormat:@" · %@ among them", keptText] : @""];
}

// always in sight, right above the picture (decided 09-10): what is left of the share, in % and MB
// and in hours of recording, with a colour and a word
- (void)refreshDiskSummary {
    TX500SSTVRecordingStore *st = self.recordings;
    NSString *state = nil;
    NSString *text = [TX500SSTVStationController diskLampTextForShare:st.diskCapBytes ? st.diskShare : 0 wantBytes:st.diskCapBytes
                                                             capBytes:st.effectiveCapBytes usedBytes:st.diskBytesUsed
                                                            keptBytes:st.keptBytes keptCount:st.keptCount state:&state];
    self.diskLampState = state;
    NSColor *c = [state isEqualToString:@"ok"] ? NSColor.systemGreenColor : [state isEqualToString:@"filling"] ? NSColor.systemYellowColor :
                 [state isEqualToString:@"low"] ? NSColor.systemRedColor : NSColor.systemGrayColor;
    self.diskSummaryLabel.backgroundColor = [c colorWithAlphaComponent:0.22];
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:[@"● " stringByAppendingString:text]
                                                                          attributes:@{NSForegroundColorAttributeName: NSColor.labelColor,
                                                                                       NSFontAttributeName: self.diskSummaryLabel.font}];
    [a addAttribute:NSForegroundColorAttributeName value:c range:NSMakeRange(0, 1)];
    self.diskSummaryLabel.attributedStringValue = a;
}

- (void)refreshStatus {
    self.enableSwitch.state = self.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    // which input it listens to, always said (SEG-2)
    self.statusLabel.stringValue = self.enabled ? (self.engine.running ? [NSString stringWithFormat:@"Listening on: %@", self.engine.source.sourceName ?: @"?"]
                                                                       : @"On, but the radio input is not open")
                                                : @"Off";
}

- (void)applyOptionsTo:(TX500SSTVEngine *)e {
    e.modeChoice = (TX500SSTVModeChoice)self.modePopup.indexOfSelectedItem;
    e.colourScale = (TX500SSTVColourScale)self.scalePopup.indexOfSelectedItem;
    e.scottieLayout = (TX500SSTVScottieLayout)self.layoutPopup.indexOfSelectedItem;
}

- (void)optionChanged:(id)sender {
    (void)sender;
    [self.defaults setInteger:self.modePopup.indexOfSelectedItem forKey:TX500SSTVModeDefaultsKey];
    [self.defaults setInteger:self.scalePopup.indexOfSelectedItem forKey:TX500SSTVScaleDefaultsKey];
    [self.defaults setInteger:self.layoutPopup.indexOfSelectedItem forKey:TX500SSTVLayoutDefaultsKey];
    [self refreshNotes];
    // the input goes on and the last minutes stay: the new settings apply from the next picture (DEC-2)
    [self applyOptionsTo:self.engine];
    if (self.engine.running) {
        [self.engine applySettings];
        NSString *say = nil;
        if (self.engine.receiving) {
            self.choiceWaiting = YES;
            say = @"The new choice applies from the next picture: this one goes on as it began. "
                  "To see it with the new choice, use Decode again when it ends.";
        } else if (sender == self.modePopup && self.modePopup.indexOfSelectedItem != TX500SSTVModeAuto)
            // a picture whose header was missed may already be on the air: the whole of it is in the last
            // minutes, not in what comes from now on (DEC-2)
            say = [NSString stringWithFormat:@"%@ from now on. If a picture was already on the air, decode the last minutes again with it "
                                             "(the first row of Recent receptions): the whole picture is there.", self.modePopup.titleOfSelectedItem];
        if (say) { self.progressLabel.stringValue = say; [self log:say]; }       // in the log too: the label changes (N-captura-10)
    }
}

#pragma mark - engines

- (void)wireEngine:(TX500SSTVEngine *)e {
    __weak TX500SSTVStationController *weakSelf = self;
    __weak TX500SSTVEngine *weakEngine = e;
    e.onProgress = ^(NSString *modeName, NSInteger rows, NSInteger height, NSBitmapImageRep *partial) {
        TX500SSTVStationController *s = weakSelf;
        if (!s) return;
        NSImage *img = [[NSImage alloc] initWithSize:partial.size];
        [img addRepresentation:partial];
        if (weakEngine != s.engine) {                                   // a WAV: its own view (SEG-22)
            s.reviewPictureView.image = img;
            s.reviewLabel.stringValue = [NSString stringWithFormat:@"Practice: %@ · %ld of %ld lines", modeName, (long)rows, (long)height];
            return;
        }
        s.pictureView.image = img;
        // while a new choice waits for the next picture, the line says so (N-captura-10). The screen's own
        // mark: the engine's is behind its lock, which it holds while it calls this
        s.progressLabel.stringValue = [NSString stringWithFormat:@"Receiving %@ · %ld of %ld lines%@", modeName, (long)rows, (long)height,
                                       (weakEngine == s.engine && s.choiceWaiting) ? @" · the new choice applies from the next picture" : @""];
    };
    e.onPicture = ^(TX500SSTVPicture *picture) { [weakSelf received:picture]; };
    e.onNotice = ^(TX500SSTVNotice *notice) {
        TX500SSTVStationController *s = weakSelf;
        if (!s || !notice.text.length) return;
        if (weakEngine == s.engine) [s readCATNow];                      // the radio's, not a practice file's
        s.progressLabel.stringValue = notice.text;
        [s log:notice.text];
    };
    e.onStopped = ^{ [weakSelf refreshStatus]; };
}

// Showing the screen never opens the audio, and Listen is not remembered: every session starts
// Off, and only the operator's own click opens the input (SEG-1 of the phase 2 review). Whether to
// remember it in some other way is left open.
- (void)activate {
    [self refreshStatus];
    [self reloadRecordings];                                    // the store is made here, with its folder and choices
}

- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    self.enabled = enabled;
    self.choiceWaiting = NO;                                    // on and off, the choices apply from the start (N2-importants-nous-7)
    BOOL ok = YES;
    (void)self.recordings;                                      // the store, with this screen's folder and choices
    if (!enabled) {
        [self.engine stop];
    } else if (!self.engine.running) {
        id<TX500SSTVAudioSource> src = [self chosenInput];
        // the Mac's own input hears the room, not the radio: it is asked before it is opened (
        // N-seguretat-5); the radio's input or a USB one is opened without asking
        BOOL builtIn = [self kindOfInputAtIndex:self.inputPopup.indexOfSelectedItem] == TX500SSTVInputBuiltIn ||
                       ([(NSObject *)src respondsToSelector:@selector(builtIn)] && [(id)src builtIn]);
        if (src && builtIn) {
            NSString *name = [(NSObject *)src respondsToSelector:@selector(deviceName)] ? [(id)src deviceName] : nil;
            BOOL yes = self.confirmBuiltInInput ? self.confirmBuiltInInput(name ?: @"") : [self askBeforeOpeningBuiltIn:name];
            if (!yes) {
                self.enabled = NO;
                NSString *why = @"Not opened: the Mac's own microphone was not confirmed. Choose the radio's input, or confirm it.";
                [self log:why];
                self.progressLabel.stringValue = why;
                if (error) *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:23 userInfo:@{NSLocalizedDescriptionKey: why}];
                [self refreshStatus];
                return NO;
            }
        }
        [self applyOptionsTo:self.engine];
        [self readCATNow];
        NSError *err = nil;
        ok = src && [self.engine startWithSource:src error:&err];
        if (!ok) {
            self.enabled = NO;                                     // nothing is open: it says Off, and why
            NSString *why = err.localizedDescription ?: @"The radio audio input could not be opened.";
            [self log:why];
            self.progressLabel.stringValue = why;
            if (error) *error = err ?: [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:22 userInfo:@{NSLocalizedDescriptionKey: why}];
        }
    }
    [self refreshStatus];
    return ok;
}

// the question itself; Cancel is the default answer
- (BOOL)askBeforeOpeningBuiltIn:(nullable NSString *)name {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Open the Mac's own microphone?";
    a.informativeText = [NSString stringWithFormat:@"%@ is built into the Mac: it hears the room, not the radio. "
                         "SSTV only receives, and nothing is sent; but what it hears is kept as any other reception.",
                         name.length ? [NSString stringWithFormat:@"«%@»", name] : @"This input"];
    [a addButtonWithTitle:@"Cancel"];
    [a addButtonWithTitle:@"Open the Mac's microphone"];
    return [a runModal] == NSAlertSecondButtonReturn;
}

- (void)enableToggled:(NSButton *)sender {
    NSError *err = nil;
    if (![self setEnabled:sender.state == NSControlStateValueOn error:&err] && err) self.progressLabel.stringValue = err.localizedDescription;
}

- (BOOL)decodeFileAtURL:(NSURL *)url synchronously:(BOOL)synchronously error:(NSError **)error {
    TX500SSTVFileSource *src = [[TX500SSTVFileSource alloc] initWithURL:url error:error];
    if (!src) return NO;
    src.asynchronous = !synchronously;
    [self applyOptionsTo:self.practiceEngine];
    self.reviewLabel.stringValue = [NSString stringWithFormat:@"Practice: decoding %@…", url.lastPathComponent];
    return [self.practiceEngine startWithSource:src error:error];
}

- (void)openFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"wav"] ?: UTTypeAudio];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSError *err = nil;
    if (![self decodeFileAtURL:panel.URL synchronously:NO error:&err]) self.progressLabel.stringValue = err.localizedDescription;
}

#pragma mark - pictures

- (NSString *)fileNameFor:(TX500SSTVPicture *)p {
    NSDateFormatter *f = [NSDateFormatter new];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    return [NSString stringWithFormat:@"SSTV-%@Z-%@%@.png", [f stringFromDate:p.endUTC], p.modeKey, p.fromFile ? @"-practice" : @""];
}

// the gallery: a PNG of its own (a picture decoded again never writes over the first one)
- (void)keepInGallery:(TX500SSTVPicture *)picture {
    [self keepInGallery:picture live:!picture.fromFile];
}

// live: a picture that just came from the radio (the live view); otherwise a WAV's or one decoded again (its own view)
- (void)keepInGallery:(TX500SSTVPicture *)picture live:(BOOL)live {
    [self.gallery addObject:picture];
    NSError *err = nil;
    if (!picture.fromFile && self.recordings.effectiveCapBytes > 0)
        [NSFileManager.defaultManager createDirectoryAtURL:self.galleryDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [self fileNameFor:picture];
    NSURL *u = [self.galleryDirectory URLByAppendingPathComponent:name];
    for (int k = 2; [NSFileManager.defaultManager fileExistsAtPath:u.path] && k < 1000; k++)
        u = [self.galleryDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.png", name.stringByDeletingPathExtension, k]];
    // on disk only a picture from the radio, and only within the disk share (nothing with Off), and not
    // when the share would remove it at once (N3-menors-oberts-3); a practice picture is saved with
    // Export… when the operator wants it
    if (!picture.fromFile && self.recordings.effectiveCapBytes > 0 &&
        [self.recordings newPictureFitsShare:(unsigned long long)(picture.width * picture.height * 3)]) {
        if ([picture writePNGToURL:u error:&err]) picture.savedURL = u;
        else [self log:[NSString stringWithFormat:@"Could not keep the picture in the gallery: %@", err.localizedDescription]];
    }
    if (live) [self showPicture:picture]; else [self showReviewPicture:picture];
    [self addThumbnail:picture];
    while (self.gallery.count > MAX(self.galleryInMemory, (NSUInteger)1)) [self forgetOldestPicture];
}

// the strip keeps the last ones; an older picture stays as its PNG in the folder
- (void)forgetOldestPicture {
    TX500SSTVPicture *old = self.gallery.firstObject;
    if (!old) return;
    [self.gallery removeObjectAtIndex:0];
    for (NSNumber *k in self.bySerial.allKeys) {
        if (self.bySerial[k] != old) continue;
        [self.bySerial removeObjectForKey:k];
        for (NSView *v in self.galleryStack.arrangedSubviews.copy)
            if ([v isKindOfClass:NSButton.class] && ((NSButton *)v).tag == k.integerValue) [v removeFromSuperview];
    }
    if (self.shownPicture == old) {
        self.shownPicture = nil;
        for (TX500SSTVPicture *p in self.gallery.reverseObjectEnumerator) if (!p.fromFile) { self.shownPicture = p; break; }
    }
    if (self.reviewPicture == old) self.reviewPicture = nil;
}


- (NSString *)galleryNameOf:(TX500SSTVPicture *)p { return p.savedURL.lastPathComponent ?: [self fileNameFor:p]; }

- (void)received:(TX500SSTVPicture *)picture {
    if (!picture.fromFile) self.choiceWaiting = NO;                 // the picture is over: the new choice applies now
    [self takePicture:picture];
    [self reloadRecordings];
}

- (void)takePicture:(TX500SSTVPicture *)picture {
    [self keepInGallery:picture];
    NSString *line = [NSString stringWithFormat:@"%@ · %ld of %ld lines%@%@", picture.modeName,
                      (long)picture.rowsReceived, (long)picture.height, picture.complete ? @"" : @" (incomplete)",
                      picture.fromFile ? @" · practice, not logged" : @""];
    if (picture.fromFile) self.reviewLabel.stringValue = line; else self.progressLabel.stringValue = line;
    NSNumber *atEnd = picture.fromFile ? nil : [self readCATNow];     // the reading as the picture ended
    // its audio, stored once, with the frequency it was received on; this picture is listed with
    // it, and so will be any "Decode again"
    TX500SSTVStoredReception *rec = nil;
    if (picture.recording) {
        uint64_t hz = picture.fromFile ? 0 : [self catFrequencyFrom:SSTVPictureStart(picture) to:picture.endUTC endReading:atEnd.unsignedLongLongValue];
        rec = [self.recordings addRecording:picture.recording catFrequencyHz:hz];
        [self.recordings addPictureNamed:[self galleryNameOf:picture] modeName:picture.modeName toReception:rec];
        picture.receptionIdentifier = rec.identifier;
        picture.recording = nil;                                    // the store alone keeps audio (DEC-4)
    }
    if (picture.fromFile) return;
    if (rec) { [self offerReception:rec picture:picture]; return; }
    // no audio was kept for it (not expected): the form all the same, with the reading as it ended
    TX500SSTVLogDraft *d = [[TX500SSTVLogDraft alloc] initWithPicture:picture catFrequencyHz:atEnd];
    d.myCallsign = self.myCallsignProvider ? self.myCallsignProvider() : nil;
    d.myGrid = self.myGridProvider ? self.myGridProvider() : nil;
    [self offerDraft:d];
}

#pragma mark - Record QSO, once per reception

- (BOOL)isWaiting:(TX500SSTVStoredReception *)r {
    if (self.draft.reception == r) return YES;
    for (TX500SSTVLogDraft *d in self.waitingDrafts) if (d.reception == r) return YES;
    return NO;
}

// the form on its own: the first time a reception from the radio gives a picture, and never again
- (void)offerReception:(TX500SSTVStoredReception *)r picture:(nullable TX500SSTVPicture *)picture {
    if (r.fromFile || r.offered || r.logged || [self isWaiting:r]) return;
    TX500SSTVLogDraft *d = [[TX500SSTVLogDraft alloc] initWithReception:r picture:picture];
    d.myCallsign = self.myCallsignProvider ? self.myCallsignProvider() : nil;
    d.myGrid = self.myGridProvider ? self.myGridProvider() : nil;
    [self offerDraft:d];
}

- (void)offerDraft:(TX500SSTVLogDraft *)d {
    if (self.draft) { [self.waitingDrafts addObject:d]; [self refreshDraftInfo]; return; }   // its turn comes after this one
    self.draft = d;
    if (d.reception) [self.recordings markOffered:d.reception];
    [self fillForm];
}

- (void)showNextDraft {
    self.draft = nil;
    while (self.waitingDrafts.count && !self.draft) {
        TX500SSTVLogDraft *d = self.waitingDrafts.firstObject;
        [self.waitingDrafts removeObjectAtIndex:0];
        if (!d.reception.logged) self.draft = d;
    }
    if (self.draft.reception) [self.recordings markOffered:self.draft.reception];
    [self fillForm];
    [self reloadRecordings];
}

- (NSUInteger)waitingForms { return self.waitingDrafts.count; }

- (BOOL)beginRecordQSOForReception:(TX500SSTVStoredReception *)reception error:(NSError **)error {
    NSString *why = reception.fromFile ? @"A reception from a file is practice: it is never logged." :
                    reception.logged ? @"This reception is already in the logbook: a reception is logged once." : nil;
    if (why) {
        self.progressLabel.stringValue = why;
        if (error) *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:11 userInfo:@{NSLocalizedDescriptionKey: why}];
        return NO;
    }
    if (self.draft.reception == reception) return YES;                 // it is the form on screen
    TX500SSTVPicture *latest = nil;
    for (TX500SSTVPicture *p in self.gallery)
        if ([reception.pictureNames containsObject:[self galleryNameOf:p]]) latest = p;
    NSMutableArray *rest = [NSMutableArray array];
    for (TX500SSTVLogDraft *d in self.waitingDrafts) if (d.reception != reception) [rest addObject:d];
    [self readForm];                                                    // what was typed on it waits with it (N-captura-1)
    if (self.draft) [rest insertObject:self.draft atIndex:0];           // the one on screen waits, it is not lost
    self.waitingDrafts = rest;
    TX500SSTVLogDraft *d = [[TX500SSTVLogDraft alloc] initWithReception:reception picture:latest];
    d.myCallsign = self.myCallsignProvider ? self.myCallsignProvider() : nil;
    d.myGrid = self.myGridProvider ? self.myGridProvider() : nil;
    self.draft = d;
    [self.recordings markOffered:reception];
    [self fillForm];
    return YES;
}

#pragma mark - Decode again

- (NSArray<TX500SSTVPicture *> *)decodeAgainReception:(TX500SSTVStoredReception *)reception mode:(TX500SSTVModeChoice)mode
                                          colourScale:(TX500SSTVColourScale)scale scottieLayout:(TX500SSTVScottieLayout)layout
                                             fitSlant:(BOOL)fitSlant slantPPM:(double)ppm {
    TX500SSTVRecording *audio = [self.recordings recordingForReception:reception];
    if (!audio) { self.reviewLabel.stringValue = @"The audio of that reception is no longer kept."; return @[]; }
    NSArray<TX500SSTVPicture *> *pics = [TX500SSTVRecordingStore decodeAgain:audio mode:mode colourScale:scale scottieLayout:layout
                                                                    fitSlant:fitSlant slantPPM:ppm];
    for (TX500SSTVPicture *p in pics) {
        p.recording = nil;                                          // the same audio: the store has it
        p.receptionIdentifier = reception.identifier;
        [self keepInGallery:p live:NO];
        [self.recordings addPictureNamed:[self galleryNameOf:p] modeName:p.modeName toReception:reception];
    }
    self.reviewLabel.stringValue = pics.count ? [NSString stringWithFormat:@"Decoded again: %@%@", pics.lastObject.modeName,
                                                   reception.fromFile ? @" · practice, not logged" : @""] :
                                     mode == TX500SSTVModeAuto ? @"Decoded again: no picture. If its header was missed, choose its mode by hand." :
                                                                 @"Decoded again: no picture with these choices.";
    if (pics.count) [self offerReception:reception picture:pics.lastObject];
    [self reloadRecordings];
    return pics;
}

// a stored reception from the radio that shares most of the shorter of the two stretches of audio:
// the same transmission (a part found by hand mid-way, and then the whole of it: N-captura-9)
- (nullable TX500SSTVStoredReception *)receptionHolding:(NSDate *)start to:(NSDate *)end {
    NSTimeInterval len = [end timeIntervalSinceDate:start];
    for (TX500SSTVStoredReception *r in self.recordings.receptions) {
        if (r.fromFile) continue;
        NSTimeInterval rlen = [r.endUTC timeIntervalSinceDate:r.startUTC];
        NSTimeInterval shorter = rlen > 0 && rlen < len ? rlen : len;
        NSDate *a = [start laterDate:r.startUTC], *b = [end earlierDate:r.endUTC];
        if (shorter > 0 && [b timeIntervalSinceDate:a] > 0.5 * shorter) return r;
    }
    return nil;
}

- (NSArray<TX500SSTVPicture *> *)decodeLastMinutesWithMode:(TX500SSTVModeChoice)mode colourScale:(TX500SSTVColourScale)scale
                                              scottieLayout:(TX500SSTVScottieLayout)layout fitSlant:(BOOL)fitSlant slantPPM:(double)ppm {
    TX500SSTVRecording *last = [self.engine lastMinutes];
    if (!last || last.duration <= 0) { self.reviewLabel.stringValue = @"No audio from the radio in the last minutes."; return @[]; }
    NSArray<TX500SSTVPicture *> *pics = [TX500SSTVRecordingStore decodeAgain:last mode:mode colourScale:scale scottieLayout:layout
                                                                    fitSlant:fitSlant slantPPM:ppm];
    for (TX500SSTVPicture *p in pics) {
        [self keepInGallery:p live:NO];
        NSDate *start = SSTVPictureStart(p);
        TX500SSTVStoredReception *rec = [self receptionHolding:start to:p.endUTC];
        if (!rec && p.recording)
            rec = [self.recordings addRecording:p.recording catFrequencyHz:last.fromFile ? 0 : [self catFrequencyFrom:start to:p.endUTC endReading:0]];
        p.recording = nil;
        if (rec) {
            p.receptionIdentifier = rec.identifier;
            [self.recordings addPictureNamed:[self galleryNameOf:p] modeName:p.modeName toReception:rec];
            [self offerReception:rec picture:p];
        }
    }
    self.reviewLabel.stringValue = pics.count ? [NSString stringWithFormat:@"From the last minutes: %@", pics.lastObject.modeName] :
                                     mode == TX500SSTVModeAuto ? @"No picture in the last minutes. If its header was missed, choose its mode by hand." :
                                                                 @"No picture in the last minutes with these choices.";
    [self reloadRecordings];
    return pics;
}

- (void)fillForm {
    TX500SSTVLogDraft *d = self.draft;
    self.recordPanel.hidden = (d == nil);
    if (!d) return;
    [self refreshDraftInfo];
    self.callField.stringValue = d.callsign;
    self.frequencyField.stringValue = d.frequencyHz ? [NSString stringWithFormat:@"%.6f", d.frequencyHz / 1e6] : @"";
    self.bandLabel.stringValue = [NSString stringWithFormat:@"Band: %@", d.band.length ? d.band : @"—"];
    self.rsvField.stringValue = d.rsv;
    self.uploadCheckbox.state = d.upload ? NSControlStateValueOn : NSControlStateValueOff;   // off for a new one
    self.uploadNote.stringValue = [TX500SSTVOptionNotes noteForUploadNow:d.upload];
    self.draftProblemLabel.stringValue = @"";
}

// The form names the picture by when it was received and shows it: from memory, else its PNG; and
// says when there is none to show (N-captura-8). It also says how many forms wait their turn.
- (void)refreshDraftInfo {
    TX500SSTVLogDraft *d = self.draft;
    if (!d) return;
    NSImage *img = d.picture ? [d.picture image] : nil;
    if (!img && d.reception) {
        NSURL *u = [self.recordings latestPictureURLOfReception:d.reception];
        if (u) img = [[NSImage alloc] initWithContentsOfURL:u];
    }
    self.draftPictureView.image = img ?: [[NSImage alloc] initWithSize:NSMakeSize(160, 128)];
    _draftShowsPicture = img != nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSUInteger n = self.waitingDrafts.count;
    // «shown here» only when it is (N2-importants-nous-5)
    self.draftInfoLabel.stringValue = [NSString stringWithFormat:@"Log the picture received at %@ UTC%@? SSTV · %@%@%@%@",
                                       [f stringFromDate:d.endUTC], img ? @" (shown here)" : @"", d.submode,
                                       d.frequencyFromCAT ? @" · frequency from the radio, as it was then" :
                                       d.reception ? @" · the radio's frequency then is not known: enter it" : @"",
                                       img ? @"" : @" · its picture is no longer kept: log it only if you know the callsign",
                                       n ? [NSString stringWithFormat:@" · %lu more waiting", (unsigned long)n] : @""];
}

- (void)readForm {
    TX500SSTVLogDraft *d = self.draft;
    if (!d) return;
    d.callsign = self.callField.stringValue ?: @"";
    // in MHz, the whole field a number from 0.5 to 56, as the Station screen takes it (TX500StationStore
    // parseMHz): «14230» or «1e30» is not a frequency, and is said (SEG-8, PRO-14)
    NSString *text = [[self.frequencyField.stringValue ?: @"" stringByReplacingOccurrencesOfString:@"," withString:@"."]
                      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSScanner *sc = [NSScanner scannerWithString:text];
    sc.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double mhz = 0;
    BOOL number = text.length && [sc scanDouble:&mhz] && sc.isAtEnd && isfinite(mhz);
    BOOL inRange = number && mhz >= 0.5 && mhz <= 56.0;
    d.frequencyHz = inRange ? (uint64_t)llround(mhz * 1e6) : 0;
    d.frequencyInvalid = text.length > 0 && !inRange;
    d.rsv = self.rsvField.stringValue ?: @"";
    d.upload = self.uploadCheckbox.state == NSControlStateValueOn;
    self.bandLabel.stringValue = [NSString stringWithFormat:@"Band: %@", d.band.length ? d.band : @"—"];
}

- (void)frequencyEdited:(id)sender { (void)sender; [self readForm]; }

- (BOOL)recordQSO:(NSError **)error {
    [self readForm];
    TX500SSTVLogDraft *d = self.draft;
    NSString *problem = d ? [d problem] : @"There is no picture to log.";
    if (problem) {
        self.draftProblemLabel.stringValue = problem;
        if (error) *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:10 userInfo:@{NSLocalizedDescriptionKey: problem}];
        return NO;
    }
    TX500LogRecord *rec = [d record];
    TX500LogbookManager *lb = self.logbook ?: [TX500LogbookManager sharedManager];
    NSError *err = nil;
    if (![lb saveContact:rec error:&err]) {
        self.draftProblemLabel.stringValue = [NSString stringWithFormat:@"Could not save: %@", err.localizedDescription ?: @"unknown error"];
        if (error) *error = err;
        return NO;
    }
    if (d.reception) [self.recordings markLogged:d.reception];
    [self log:[NSString stringWithFormat:@"Logged %@ (SSTV %@)%@", rec.callsign, d.submode,
               d.upload ? @"; upload asked" : @"; not uploaded now: pending in the Logbook until Sync All or Sync Selected"]];
    if (d.upload) {
        if (self.uploadHandler) self.uploadHandler(rec);
        else {
            __weak TX500SSTVStationController *weakSelf = self;
            NSString *call = rec.callsign;
            [[TX500CloudSyncEngine sharedEngine] uploadContactImmediately:rec completion:^(BOOL ok, NSString *summary) {
                [weakSelf log:[NSString stringWithFormat:@"Upload of %@: %@", call, ok ? (summary.length ? summary : @"done") :
                               (summary.length ? summary : @"it did not go through")]];
            }];
        }
    }
    [self showNextDraft];
    self.progressLabel.stringValue = [NSString stringWithFormat:@"Logged %@.", rec.callsign];
    return YES;
}

- (void)uploadToggled:(id)sender {
    (void)sender;
    self.uploadNote.stringValue = [TX500SSTVOptionNotes noteForUploadNow:self.uploadCheckbox.state == NSControlStateValueOn];
}

- (void)recordClicked:(id)sender { (void)sender; [self recordQSO:nil]; }

- (void)discardQSO {
    if (self.draft) [self log:@"Picture not logged (discarded)."];
    [self showNextDraft];
}

- (void)discardClicked:(id)sender { (void)sender; [self discardQSO]; }

- (void)showPicture:(TX500SSTVPicture *)picture {
    self.shownPicture = picture;
    self.pictureView.image = [picture image];
    self.exportButton.enabled = YES;
}

- (void)showReviewPicture:(TX500SSTVPicture *)picture {
    self.reviewPicture = picture;
    self.reviewPictureView.image = [picture image];
    self.reviewExportButton.enabled = YES;
}

// a small copy for the strip, not the full picture a second time
static NSImage *SSTVThumbnail(TX500SSTVPicture *p) {
    NSImage *full = [p image];
    NSImage *t = [[NSImage alloc] initWithSize:NSMakeSize(90, 72)];
    [t lockFocus];
    [full drawInRect:NSMakeRect(0, 0, 90, 72) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1.0];
    [t unlockFocus];
    return t;
}

- (void)addThumbnail:(TX500SSTVPicture *)picture {
    NSButton *b = [NSButton buttonWithImage:SSTVThumbnail(picture) target:self action:@selector(thumbnailClicked:)];
    b.imageScaling = NSImageScaleProportionallyUpOrDown;
    b.bordered = NO;
    b.tag = ++self.serial;
    self.bySerial[@(b.tag)] = picture;
    b.toolTip = [NSString stringWithFormat:@"%@%@", picture.modeName, picture.fromFile ? @" (practice)" : @""];
    [b.widthAnchor constraintEqualToConstant:90].active = YES;
    [b.heightAnchor constraintEqualToConstant:72].active = YES;
    [self.galleryStack addArrangedSubview:b];
}

- (void)thumbnailClicked:(NSButton *)sender {
    TX500SSTVPicture *p = self.bySerial[@(sender.tag)];
    if (p) [self showReviewPicture:p];                              // the gallery shows in its own view: never over the live one
}

- (BOOL)exportPicture:(TX500SSTVPicture *)picture toURL:(NSURL *)url error:(NSError **)error {
    return [picture writePNGToURL:url error:error];
}

- (void)exportReview:(id)sender { (void)sender; [self exportPictureWithPanel:self.reviewPicture]; }

- (void)exportShown:(id)sender { (void)sender; [self exportPictureWithPanel:self.shownPicture]; }

- (void)exportPictureWithPanel:(nullable TX500SSTVPicture *)p {
    if (!p) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [self fileNameFor:p];
    panel.allowedContentTypes = @[UTTypePNG];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSError *err = nil;
    if (![self exportPicture:p toURL:panel.URL error:&err]) self.progressLabel.stringValue = err.localizedDescription;
}


#pragma mark - the recent receptions

// The list reads the store only once it exists: building the screen never makes it (its folder
// and choices are given after; the screen's activate makes it)
- (nullable TX500SSTVStoredReception *)receptionAtRow:(NSInteger)row {
    NSArray *r = self.store.receptions;
    return (row >= 1 && row <= (NSInteger)r.count) ? r[(NSUInteger)row - 1] : nil;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return 1 + (NSInteger)self.store.receptions.count; }

static NSString *SSTVUTC(NSDate *d) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [f stringFromDate:d];
}

// a received picture is not a QSO (a QSO is a two-way contact): the list says what it is
- (NSString *)textForRow:(NSInteger)row column:(NSString *)column {
    // the last minutes, without copying them (N-memoria-disc-4): they stay in memory until the app
    // quits, also with Listen Off, and the row says when they end
    if (row == 0) {
        NSUInteger bytes = self.engine.lastMinutesByteSize;
        BOOL on = self.engine.running;
        if ([column isEqualToString:@"ended"]) return on ? @"now" : bytes ? SSTVUTC(self.engine.lastMinutesEndUTC) : @"—";
        if ([column isEqualToString:@"mode"]) return @"Last 5 minutes (no picture detected)";
        if ([column isEqualToString:@"from"]) return @"Radio";
        if ([column isEqualToString:@"audio"]) return bytes ? [NSString stringWithFormat:@"%.1f MB (memory)", bytes / 1e6] : @"—";
        if ([column isEqualToString:@"status"])
            return on ? @"listening · in memory only" : bytes ? @"Listen is Off · in memory until the app quits" : @"Listen has not been on";
        return @"—";
    }
    TX500SSTVStoredReception *r = [self receptionAtRow:row];
    if (!r) return @"";
    if ([column isEqualToString:@"ended"]) return SSTVUTC(r.endUTC);
    if ([column isEqualToString:@"mode"])
        return r.modeName.length ? r.modeName : r.modeKey.length ? r.modeKey : @"Last minutes, kept (no picture detected)";
    if ([column isEqualToString:@"from"]) return r.fromFile ? @"File" : @"Radio";
    if ([column isEqualToString:@"pictures"]) return [NSString stringWithFormat:@"%lu", (unsigned long)r.pictureNames.count];
    if ([column isEqualToString:@"audio"])
        return r.inMemory || r.onDisk ? [NSString stringWithFormat:@"%.1f MB%@", r.byteSize / 1e6, r.onDisk ? @"" : @" (memory)"] : @"gone";
    if ([column isEqualToString:@"status"])
        return r.fromFile ? @"practice (file)" : !r.pictureNames.count ? @"audio only · no picture yet (Decode again)" :
               r.logged ? @"received picture · logged" :
               r.offered ? @"received picture · reviewed, not logged" : @"received picture · pending review";
    return @"";
}

- (nullable id)tableView:(NSTableView *)tableView objectValueForTableColumn:(nullable NSTableColumn *)col row:(NSInteger)row {
    (void)tableView;
    if ([col.identifier isEqualToString:@"keep"]) { TX500SSTVStoredReception *r = [self receptionAtRow:row]; return r ? (r.keep ? @"yes" : @"") : @""; }
    return [self textForRow:row column:col.identifier];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n { (void)n; [self updateRowButtons]; }

- (void)reloadRecordings {
    [self.recordingsTable reloadData];
    [self updateRowButtons];
    [self refreshDiskSummary];
}

- (void)updateRowButtons {
    NSInteger row = self.recordingsTable.selectedRow;
    TX500SSTVStoredReception *r = [self receptionAtRow:row];
    BOOL any = row >= 0;
    self.decodeAgainButton.enabled = any;
    BOOL ring = row == 0 && self.engine.lastMinutesByteSize > 0;
    self.exportRecordingButton.enabled = any && (ring || (r && (r.inMemory || r.onDisk)));
    // Keep on the last minutes keeps a copy of them as a recording of its own (the only way they reach the disk)
    self.keepCheckbox.enabled = ring || (r != nil && (r.inMemory || r.onDisk) && !(r.fromFile && !r.onDisk));   // practice: never to disk
    // the last minutes show ticked when their copy is kept (N3-menors-oberts-1)
    self.keepCheckbox.state = (r ?: (ring ? [self keptCopyOfLastMinutes] : nil)).keep ? NSControlStateValueOn : NSControlStateValueOff;
    self.recordRowButton.enabled = r && !r.fromFile && !r.logged && r.pictureNames.count > 0;   // a picture to log first
    self.discardRowButton.enabled = r && !r.fromFile && !r.logged && !r.offered;
}

- (void)paneChosen:(NSSegmentedControl *)sender {
    BOOL fax = sender.selectedSegment == 1;
    self.sstvPane.hidden = fax;
    self.faxController.view.hidden = !fax;
}

- (void)toggleAgainPanel:(id)sender { (void)sender; self.againPanel.hidden = !self.againPanel.hidden; }

- (void)againGoClicked:(id)sender {
    (void)sender;
    NSInteger row = self.recordingsTable.selectedRow;
    TX500SSTVModeChoice mode = (TX500SSTVModeChoice)self.againModePopup.indexOfSelectedItem;
    TX500SSTVColourScale scale = (TX500SSTVColourScale)self.againScalePopup.indexOfSelectedItem;
    TX500SSTVScottieLayout layout = (TX500SSTVScottieLayout)self.againLayoutPopup.indexOfSelectedItem;
    if (row == 0) [self decodeLastMinutesWithMode:mode colourScale:scale scottieLayout:layout fitSlant:YES slantPPM:0];
    else if ([self receptionAtRow:row])
        [self decodeAgainReception:[self receptionAtRow:row] mode:mode colourScale:scale scottieLayout:layout fitSlant:YES slantPPM:0];
    [self reloadRecordings];
}

- (void)keepClicked:(NSButton *)sender {
    NSInteger row = self.recordingsTable.selectedRow;
    TX500SSTVStoredReception *r = [self receptionAtRow:row];
    BOOL keep = sender.state == NSControlStateValueOn;
    // the last minutes: Keep makes their one copy (or finds it), and the list goes to its row, where it
    // shows ticked and can be unticked; untick on the last minutes lets that copy go
    if (row == 0) r = keep ? [self keepLastMinutes] : [self keptCopyOfLastMinutes];
    if (!r) { [self reloadRecordings]; return; }
    NSError *err = nil;
    BOOL off = self.recordings.diskCapBytes == 0;
    if (![self.recordings setKeep:keep forReception:r error:&err])
        self.progressLabel.stringValue = err.localizedDescription ?: @"It could not be kept.";
    else if (keep && off) {
        // with the disk Off, Keep saves that one recording: the operator's own choice, and said (DEC-17)
        NSString *t = @"Kept on disk although the disk is Off: your choice, for this recording only. It never expires; untick Keep to let it go.";
        self.progressLabel.stringValue = t;
        [self log:t];
    }
    [self reloadRecordings];
    if (row == 0 && keep) {
        NSUInteger i = [self.recordings.receptions indexOfObject:r];
        if (i != NSNotFound) [self.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i + 1] byExtendingSelection:NO];
    }
}

// the last minutes as a recording of their own, from the radio, kept: one copy of the same minutes,
// written at once, with no place in memory; nil if there is nothing, or it could not be written (no row).
// No form is marked offered: a picture decoded again from it later opens its form (N3-importants-nous-2)
- (nullable TX500SSTVStoredReception *)keepLastMinutes {
    TX500SSTVRecording *last = self.engine.lastMinutes;
    if (!last || last.duration <= 0) { self.progressLabel.stringValue = @"No audio from the radio in the last minutes."; return nil; }
    if (last.fromFile) { self.progressLabel.stringValue = @"Practice recordings are never saved on disk: use Export recording… to keep a copy."; return nil; }
    NSDate *end = last.endUTC ?: [NSDate date], *start = [end dateByAddingTimeInterval:-last.duration];
    NSError *err = nil;
    TX500SSTVStoredReception *rec = [self.recordings keepCopyOfRecording:last catFrequencyHz:[self catFrequencyFrom:start to:end endReading:0]
                                                                  error:&err];
    if (!rec) self.progressLabel.stringValue = err.localizedDescription ?: @"It could not be kept.";
    return rec;
}

// the copy already kept of the last minutes as they are now, or nil
- (nullable TX500SSTVStoredReception *)keptCopyOfLastMinutes {
    TX500SSTVStoredReception *r = [self.recordings receptionFromRadioEndingAt:self.engine.lastMinutesEndUTC
                                                                     byteSize:self.engine.lastMinutesByteSize];
    return r.keep ? r : nil;
}

- (void)exportRecordingClicked:(id)sender {
    (void)sender;
    NSInteger row = self.recordingsTable.selectedRow;
    TX500SSTVRecording *audio = row == 0 ? self.engine.lastMinutes :
                                [self receptionAtRow:row] ? [self.recordings recordingForReception:[self receptionAtRow:row]] : nil;
    if (!audio) { self.progressLabel.stringValue = @"That audio is no longer kept."; return; }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"SSTV-recording-%@.wav", [SSTVUTC(audio.endUTC) stringByReplacingOccurrencesOfString:@":" withString:@""]];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"wav"] ?: UTTypeAudio];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSError *err = nil;
    if (![audio writeWAVToURL:panel.URL error:&err]) self.progressLabel.stringValue = err.localizedDescription;
}

- (void)recordRowClicked:(id)sender {
    (void)sender;
    TX500SSTVStoredReception *r = [self receptionAtRow:self.recordingsTable.selectedRow];
    if (r) [self beginRecordQSOForReception:r error:nil];
    [self reloadRecordings];
}

// reviewed, not logged: it can still be logged later, from its row
- (void)discardRowClicked:(id)sender {
    (void)sender;
    TX500SSTVStoredReception *r = [self receptionAtRow:self.recordingsTable.selectedRow];
    if (r && !r.logged) {
        [self.recordings markOffered:r];
        NSMutableArray *rest = [NSMutableArray array];                  // its form, if one waits, goes too (N-captura-6)
        for (TX500SSTVLogDraft *d in self.waitingDrafts) if (d.reception != r) [rest addObject:d];
        self.waitingDrafts = rest;
        [self refreshDraftInfo];
    }
    [self reloadRecordings];
}

@end
