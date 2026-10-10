// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500FaxStationController.h"
#import "TX500SSTVOptionNotes.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TX500FaxStationController ()
@property (nonatomic, readwrite) NSView *view;
@property (nonatomic, readwrite) TX500FaxEngine *engine;
@property (nonatomic, readwrite, copy, nullable) NSURL *fileURL;
@property (nonatomic, readwrite) NSInteger shownChart;
@property (nonatomic, readwrite) NSPopUpButton *deviationPopup, *lpmPopup, *iocPopup, *widthPopup, *lineStartPopup, *chartPopup;
@property (nonatomic, readwrite) NSTextField *deviationNote, *lpmNote, *iocNote, *widthNote, *lineStartNote;
@property (nonatomic, readwrite) NSTextField *infoLabel, *noticeLabel, *practiceLabel, *marginLabel, *errorLabel;
@property (nonatomic, readwrite) NSSlider *marginSlider;
@property (nonatomic, readwrite) NSImageView *pictureView;
@property (nonatomic, readwrite) NSButton *openButton, *againButton, *exportButton;
@end

static NSTextField *FaxNote(void) {
    NSTextField *f = [NSTextField wrappingLabelWithString:@""];
    f.font = [NSFont systemFontOfSize:11];
    f.textColor = NSColor.secondaryLabelColor;
    [f.widthAnchor constraintLessThanOrEqualToConstant:420].active = YES;
    return f;
}

static NSStackView *FaxRow(NSArray<NSView *> *v) {
    NSStackView *s = [NSStackView stackViewWithViews:v];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal; s.alignment = NSLayoutAttributeCenterY; s.spacing = 8;
    return s;
}

static NSStackView *FaxColumn(NSArray<NSView *> *v, CGFloat spacing) {
    NSStackView *s = [NSStackView stackViewWithViews:v];
    s.orientation = NSUserInterfaceLayoutOrientationVertical; s.alignment = NSLayoutAttributeLeading; s.spacing = spacing;
    return s;
}

@implementation TX500FaxStationController

- (instancetype)init {
    if ((self = [super init])) {
        _engine = [TX500FaxEngine new];
        [self buildView];
    }
    return self;
}

- (NSPopUpButton *)popupFor:(NSString *)selector {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray<NSString *> *o in [TX500SSTVOptionNotes faxOptionsFor:selector]) [p addItemWithTitle:o[0]];
    [p selectItemAtIndex:0];
    p.target = self; p.action = @selector(optionChanged:);
    return p;
}

- (void)buildView {
    NSTextField *intro = FaxNote();
    intro.stringValue = @"Radiofax, files only for now: it decodes a WAV file you open; it does not listen to the radio yet. "
                        @"Receive only. A chart is no contact: nothing here is ever logged.";
    self.openButton = [NSButton buttonWithTitle:@"Open WAV…" target:self action:@selector(openClicked:)];
    self.againButton = [NSButton buttonWithTitle:@"Decode again" target:self action:@selector(againClicked:)];
    self.exportButton = [NSButton buttonWithTitle:@"Export…" target:self action:@selector(exportClicked:)];
    self.againButton.enabled = NO; self.exportButton.enabled = NO;
    self.practiceLabel = FaxNote();
    // what could not be done, apart from the file's own lines (N2-fax-app-17)
    self.errorLabel = FaxNote();
    self.errorLabel.textColor = NSColor.systemRedColor;
    self.errorLabel.hidden = YES;
    self.chartPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.chartPopup.target = self; self.chartPopup.action = @selector(chartChosen:);
    self.chartPopup.hidden = YES;

    self.pictureView = [NSImageView imageViewWithImage:[[NSImage alloc] initWithSize:NSMakeSize(604, 400)]];
    self.pictureView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.pictureView.imageFrameStyle = NSImageFrameGrayBezel;
    [self.pictureView.widthAnchor constraintEqualToConstant:604].active = YES;
    [self.pictureView.heightAnchor constraintEqualToConstant:400].active = YES;
    self.infoLabel = FaxNote();
    self.noticeLabel = FaxNote();
    self.marginSlider = [NSSlider sliderWithValue:0 minValue:-120 maxValue:120 target:self action:@selector(marginMoved:)];
    [self.marginSlider.widthAnchor constraintEqualToConstant:260].active = YES;
    self.marginSlider.enabled = NO;
    self.marginLabel = [NSTextField labelWithString:@"0 points"];

    self.deviationPopup = [self popupFor:@"deviation"]; self.deviationNote = FaxNote();
    self.lpmPopup = [self popupFor:@"lpm"]; self.lpmNote = FaxNote();
    self.iocPopup = [self popupFor:@"ioc"]; self.iocNote = FaxNote();
    self.widthPopup = [self popupFor:@"width"]; self.widthNote = FaxNote();
    self.lineStartPopup = [self popupFor:@"lineStart"]; self.lineStartNote = FaxNote();

    NSStackView *left = FaxColumn(@[intro, FaxRow(@[self.openButton, self.againButton, self.exportButton, self.chartPopup]),
                                    self.errorLabel, self.practiceLabel, self.pictureView,
                                    FaxRow(@[[NSTextField labelWithString:@"Margin, after receiving:"], self.marginSlider, self.marginLabel]),
                                    self.infoLabel, self.noticeLabel], 8);
    NSStackView *right = FaxColumn(@[
        [NSTextField labelWithString:@"Options (each with what it is good and not good for)"],
        FaxRow(@[[NSTextField labelWithString:@"Deviation:"], self.deviationPopup]), self.deviationNote,
        FaxRow(@[[NSTextField labelWithString:@"Lines per minute:"], self.lpmPopup]), self.lpmNote,
        FaxRow(@[[NSTextField labelWithString:@"Index of cooperation:"], self.iocPopup]), self.iocNote,
        FaxRow(@[[NSTextField labelWithString:@"Saved width:"], self.widthPopup]), self.widthNote,
        FaxRow(@[[NSTextField labelWithString:@"Line start:"], self.lineStartPopup]), self.lineStartNote], 6);
    NSStackView *root = FaxRow(@[left, right]);
    root.alignment = NSLayoutAttributeTop;
    root.spacing = 18;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    self.view = root;
    [self refreshNotes];
}

- (void)refreshNotes {
    NSDictionary *pairs = @{@"deviation": @[self.deviationPopup, self.deviationNote], @"lpm": @[self.lpmPopup, self.lpmNote],
                            @"ioc": @[self.iocPopup, self.iocNote], @"width": @[self.widthPopup, self.widthNote],
                            @"lineStart": @[self.lineStartPopup, self.lineStartNote]};
    for (NSString *k in pairs) {
        NSPopUpButton *p = pairs[k][0];
        NSArray *opts = [TX500SSTVOptionNotes faxOptionsFor:k];
        NSInteger i = p.indexOfSelectedItem;
        ((NSTextField *)pairs[k][1]).stringValue = (i >= 0 && i < (NSInteger)opts.count) ? opts[(NSUInteger)i][1] : @"";
    }
}

- (void)optionChanged:(id)sender {
    (void)sender;
    // the saved width is chosen at IOC 576 only: at 288 it is π × 288 (905 points), and the note says so (N2-fax-app-12)
    BOOL ioc576 = self.iocPopup.indexOfSelectedItem != 1;
    self.widthPopup.enabled = ioc576;
    [self refreshNotes];
    if (!ioc576) self.widthNote.stringValue = @"At IOC 288 the width is π × 288 = 905 points: this choice applies at IOC 576 only.";
}

- (void)sayError:(nullable NSString *)text {
    self.errorLabel.stringValue = text ?: @"";
    self.errorLabel.hidden = text.length == 0;
}

- (nullable NSTextField *)noteForPopup:(NSPopUpButton *)popup {
    NSArray *pairs = @[@[self.deviationPopup, self.deviationNote], @[self.lpmPopup, self.lpmNote], @[self.iocPopup, self.iocNote],
                       @[self.widthPopup, self.widthNote], @[self.lineStartPopup, self.lineStartNote]];
    for (NSArray *pr in pairs) if (pr[0] == popup) return pr[1];
    return nil;
}

- (void)applyChoices {
    static const double dev[] = {400, 425, 300, 150};
    static const double lpm[] = {120, 60, 90, 240};
    static const int ioc[] = {576, 288};
    NSInteger d = self.deviationPopup.indexOfSelectedItem, l = self.lpmPopup.indexOfSelectedItem, c = self.iocPopup.indexOfSelectedItem;
    self.engine.deviationHz = dev[(d >= 0 && d < 4) ? d : 0];
    self.engine.lpm = lpm[(l >= 0 && l < 4) ? l : 0];
    self.engine.ioc = ioc[(c >= 0 && c < 2) ? c : 0];
    // 1810 (the standard, π × 576 rounded) or 1809 (fldigi's); at IOC 288, the standard π × 288
    self.engine.width = self.widthPopup.indexOfSelectedItem == 1 && self.engine.ioc == 576 ? 1809 : 0;
    self.engine.lineStart = (TX500FaxLineStart)self.lineStartPopup.indexOfSelectedItem;
}

- (BOOL)decodeFileAtURL:(NSURL *)url error:(NSError **)error {
    [self applyChoices];
    if (![self.engine decodeFileAtURL:url error:error]) return NO;
    [self sayError:nil];
    self.fileURL = url;
    [self.chartPopup removeAllItems];
    NSArray<TX500FaxChart *> *charts = self.engine.charts;
    for (NSUInteger k = 0; k < charts.count; k++)
        [self.chartPopup addItemWithTitle:[NSString stringWithFormat:@"Chart %lu of %lu", (unsigned long)k + 1, (unsigned long)charts.count]];
    self.chartPopup.hidden = charts.count < 2;
    self.againButton.enabled = YES;
    self.practiceLabel.stringValue = [NSString stringWithFormat:@"%@: a file: practice, never logged.", url.lastPathComponent];
    NSMutableArray *lines = [NSMutableArray array];
    for (TX500FaxNotice *n in self.engine.notices) [lines addObject:n.text];
    self.noticeLabel.stringValue = [lines componentsJoinedByString:@"\n"];
    if (self.logHandler) for (NSString *t in lines) self.logHandler([@"[Fax] " stringByAppendingString:t]);
    [self showChart:0];
    return YES;
}

- (BOOL)decodeAgain:(NSError **)error {
    if (!self.fileURL) { if (error) *error = [NSError errorWithDomain:@"TX500FaxErrorDomain" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Open a WAV first."}]; return NO; }
    return [self decodeFileAtURL:self.fileURL error:error];
}

- (void)showChart:(NSInteger)i {
    NSArray<TX500FaxChart *> *charts = self.engine.charts;
    self.shownChart = i;
    self.marginSlider.doubleValue = 0; self.marginLabel.stringValue = @"0 points";
    if (i < 0 || i >= (NSInteger)charts.count) {
        self.pictureView.image = [[NSImage alloc] initWithSize:NSMakeSize(604, 400)];
        self.infoLabel.stringValue = @"No chart in this file.";
        self.exportButton.enabled = NO; self.marginSlider.enabled = NO;
        return;
    }
    TX500FaxChart *c = charts[(NSUInteger)i];
    self.pictureView.image = [c image];
    NSString *phasing = c.phasingKind == 0 ? @"no phasing" : [NSString stringWithFormat:@"phasing %@%@, %ld lines",
                        c.phasingKind == 2 ? @"symmetric" : @"5/95", c.phasingInverted ? @" inverted" : @"", (long)c.phasingLines];
    self.infoLabel.stringValue = [NSString stringWithFormat:@"%ld lines%@ · %@ · %.4f ms per line (%+.1f ppm) · tuning %+.1f Hz · margin from %@%@",
                                  (long)c.height, c.complete ? @"" : @" (incomplete)", phasing, c.linePeriodMs, c.slantPPM,
                                  c.offsetHz, c.marginSource,
                                  c.lostLines ? [NSString stringWithFormat:@" · %ld lines lost in cuts, in grey", (long)c.lostLines] : @""];
    self.exportButton.enabled = YES;
    self.marginSlider.enabled = YES;
}

- (void)setMarginPoints:(double)points {
    if (![self.engine moveMarginOfChart:self.shownChart byPoints:points]) return;
    self.marginSlider.doubleValue = points;
    self.marginLabel.stringValue = [NSString stringWithFormat:@"%.0f points", points];
    self.pictureView.image = [self.engine.charts[(NSUInteger)self.shownChart] image];
}

- (BOOL)exportShownToURL:(NSURL *)url error:(NSError **)error {
    NSArray<TX500FaxChart *> *charts = self.engine.charts;
    if (self.shownChart < 0 || self.shownChart >= (NSInteger)charts.count) return NO;
    return [charts[(NSUInteger)self.shownChart] writePNGToURL:url error:error];
}

#pragma mark - actions

- (void)openClicked:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"wav"] ?: UTTypeAudio];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    [self openFileAtURL:panel.URL];
}

- (BOOL)openFileAtURL:(NSURL *)url {
    NSError *err = nil;
    if ([self decodeFileAtURL:url error:&err]) return YES;
    [self sayError:err.localizedDescription ?: @"The file could not be read."];
    return NO;
}

- (void)againClicked:(id)sender {
    (void)sender;
    NSError *err = nil;
    if (![self decodeAgain:&err]) [self sayError:err.localizedDescription ?: @"It could not be decoded again."];
}

- (void)chartChosen:(NSPopUpButton *)sender { [self showChart:sender.indexOfSelectedItem]; }

- (void)marginMoved:(NSSlider *)sender { [self setMarginPoints:round(sender.doubleValue)]; }

- (void)exportClicked:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"%@-chart-%ld.png",
                                  self.fileURL.lastPathComponent.stringByDeletingPathExtension ?: @"fax", (long)self.shownChart + 1];
    panel.allowedContentTypes = @[UTTypePNG];
    if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
    NSError *err = nil;
    if (![self exportShownToURL:panel.URL error:&err]) [self sayError:err.localizedDescription ?: @"The chart could not be saved."];
}
@end
