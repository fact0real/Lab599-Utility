#import "TX500PowerCalibrationController.h"
#import "TX500PowerCalibration.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TX500CalibrationDocumentView : NSView
@end
@implementation TX500CalibrationDocumentView
- (BOOL)isFlipped { return YES; }
@end

@interface TX500PowerCalibrationController ()
@property TX500PowerCalibration *calibration;
@property NSMutableDictionary<NSString *,NSTextField *> *fields;
@property NSPopUpButton *model;
@property NSPopUpButton *method;
@property NSPopUpButton *groupPopup;
@property NSPopUpButton *meter;
@property NSTextView *report;
@property NSTextField *lookupDots;
@property NSTextField *result;
@property NSTextField *status;
@property NSButton *confirmed;
@property NSArray<NSArray<NSDictionary *> *> *measurementGroups;
@end

@implementation TX500PowerCalibrationController
- (instancetype)init {
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,950,790)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self=[super initWithWindow:window])) {
        self.calibration=[TX500PowerCalibration new]; self.fields=[NSMutableDictionary new];
        window.title=@"Power Calibration — External Wattmeter";
        window.releasedWhenClosed=NO;
        window.minSize=NSMakeSize(820,700); [window center];
        [self buildUI]; [self refresh:nil];
    }
    return self;
}
- (NSButton *)button:(NSString *)title action:(SEL)action {
    return [NSButton buttonWithTitle:title target:self action:action];
}
- (void)buildUI {
    NSTextField *intro=[NSTextField wrappingLabelWithString:@"Compare TX meter dots with watts recorded from an external wattmeter into a 50 Ω dummy load. Operate the radio manually using its own controls. This window does not connect to or transmit with the radio. Tables are estimates for the recorded conditions; they are not live RF measurements."];
    intro.font=[NSFont systemFontOfSize:12];
    NSStackView *files=[NSStackView stackViewWithViews:@[
        [self button:@"Import Sweep CSV (replace)…" action:@selector(importCSV:)],
        [self button:@"Export Measurements…" action:@selector(exportCSV:)],
        [self button:@"Export Analysis…" action:@selector(exportReport:)],
        [self button:@"New Session" action:@selector(clear:)]]];
    files.spacing=8;
    self.model=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.model addItemsWithTitles:@[@"TX-500",@"TX-500 Discovery",@"TX-500MP",@"TX-500PRO",@"TX-500PRO ALTAI"]];
    self.method=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.method addItemsWithTitles:@[@"cg",@"tone",@"cw",@"dig"]];
    NSArray *specs=@[@[@"Callsign",@"callsign",@"Operator"],@[@"Radio / unit label",@"radio_unit",@"Identify this individual radio"],
        @[@"Firmware",@"firmware",@"e.g. 1.30.00"],@[@"Instrument",@"instrument",@"Wattmeter make / model"],
        @[@"Supply voltage (V)",@"supply_voltage_v",@"Measured, 9–15"],@[@"Frequency (Hz)",@"freq_hz",@"e.g. 14045000"],
        @[@"Band",@"band",@"e.g. 20m"],@[@"PC requested (10–100)",@"pc_set",@"Raw PC value"],
        @[@"PC read-back",@"pc_readback",@"Raw PC reply"],@[@"SM0 TX dots (0–30)",@"sm_dots",@"Optional if RM0 entered"],
        @[@"RM0 TX dots (0–30)",@"rm_power_dots",@"Optional if SM0 entered"],@[@"Wattmeter reading (W)",@"measured_w",@"Actual measured watts"],
        @[@"Notes",@"notes",@"Load, temperature, method details"],@[@"Raw VL reply",@"vl_raw",@"Optional, unconverted"]];
    NSMutableArray *gridRows=[NSMutableArray arrayWithObject:@[[NSTextField labelWithString:@"Radio model"],self.model,
        [NSTextField labelWithString:@"Carrier used"],self.method]];
    for (NSUInteger i=0;i<specs.count;i+=2) {
        NSMutableArray *r=[NSMutableArray new];
        for (NSUInteger j=i;j<i+2;j++) {
            NSArray *spec=specs[j]; NSTextField *f=[NSTextField textFieldWithString:@""];
            f.placeholderString=spec[2]; self.fields[spec[1]]=f;
            [f.widthAnchor constraintGreaterThanOrEqualToConstant:180].active=YES;
            [r addObject:[NSTextField labelWithString:spec[0]]]; [r addObject:f];
        }
        [gridRows addObject:r];
    }
    NSGridView *grid=[NSGridView gridViewWithViews:gridRows]; grid.columnSpacing=10; grid.rowSpacing=5;
    self.confirmed=[NSButton checkboxWithTitle:@"I recorded this point during confirmed TX into a rated 50 Ω dummy load, then returned to RX." target:nil action:nil];
    self.confirmed.font=[NSFont systemFontOfSize:11];
    NSStackView *addRow=[NSStackView stackViewWithViews:@[self.confirmed,[self button:@"Add Point" action:@selector(addPoint:)]]];
    addRow.spacing=10;
    self.groupPopup=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.groupPopup.target=self; self.groupPopup.action=@selector(updateReport:);
    [self.groupPopup.widthAnchor constraintLessThanOrEqualToConstant:680].active=YES;
    [self.groupPopup setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.meter=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.meter addItemsWithTitles:@[@"SM0 TX",@"RM0 POWER"]];
    self.meter.target=self; self.meter.action=@selector(updateReport:);
    NSStackView *select=[NSStackView stackViewWithViews:@[self.groupPopup,self.meter]]; select.spacing=10;
    NSScrollView *scroll=[NSScrollView new]; scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
    self.report=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,850,180)];
    self.report.editable=NO; self.report.richText=NO;
    self.report.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.report.autoresizingMask=NSViewWidthSizable; self.report.textContainer.widthTracksTextView=YES;
    scroll.documentView=self.report;
    [scroll.heightAnchor constraintEqualToConstant:220].active=YES;
    self.lookupDots=[NSTextField textFieldWithString:@""]; self.lookupDots.placeholderString=@"0–30 dots";
    [self.lookupDots.widthAnchor constraintEqualToConstant:90].active=YES;
    self.result=[NSTextField labelWithString:@"No estimate yet."];
    NSStackView *lookup=[NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Table lookup:"],self.lookupDots,
        [self button:@"Estimate W" action:@selector(lookup:)],self.result]]; lookup.spacing=8;
    self.status=[NSTextField wrappingLabelWithString:@"Local session only. Export measurements before closing the app."];
    self.status.font=[NSFont systemFontOfSize:11];
    NSStackView *stack=[NSStackView stackViewWithViews:@[intro,files,grid,addRow,select,scroll,lookup,self.status]];
    stack.orientation=NSUserInterfaceLayoutOrientationVertical; stack.alignment=NSLayoutAttributeLeading;
    stack.spacing=10; stack.translatesAutoresizingMaskIntoConstraints=NO;
    NSScrollView *outer=[NSScrollView new]; outer.hasVerticalScroller=YES;
    outer.translatesAutoresizingMaskIntoConstraints=NO;
    TX500CalibrationDocumentView *document=[TX500CalibrationDocumentView new];
    document.translatesAutoresizingMaskIntoConstraints=NO; outer.documentView=document;
    [self.window.contentView addSubview:outer]; [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [outer.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor],
        [outer.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor],
        [outer.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor],
        [outer.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor],
        [document.widthAnchor constraintEqualToAnchor:outer.contentView.widthAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-18],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-18],
        [intro.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [self.status.widthAnchor constraintEqualToAnchor:stack.widthAnchor]]];
}
- (void)refresh:(id)sender {
    self.measurementGroups=[self.calibration groups];
    [self.groupPopup removeAllItems];
    for (NSArray *g in self.measurementGroups) [self.groupPopup addItemWithTitle:[TX500PowerCalibration groupTitle:g]];
    [self updateReport:nil];
}
- (NSArray *)selectedRows {
    NSInteger i=self.groupPopup.indexOfSelectedItem;
    return i>=0 && (NSUInteger)i<self.measurementGroups.count ? self.measurementGroups[i] : @[];
}
- (NSString *)meterKey { return self.meter.indexOfSelectedItem==0 ? @"sm_dots" : @"rm_power_dots"; }
- (void)updateReport:(id)sender {
    NSArray *rows=[self selectedRows];
    self.groupPopup.toolTip=rows.count ? [TX500PowerCalibration groupTitle:rows] : @"";
    self.report.string=rows.count ? [TX500PowerCalibration reportForRows:rows meter:[self meterKey]] :
        @"Import a sweep CSV or enter external wattmeter observations.\nSimulated rows and rows without measured watts are excluded.\nModel, firmware, frequency, voltage, carrier, operator, instrument and unit label form separate groups.\nUse one physical radio per session when imported data has no unit label.\nNo calibration is applied to the live radio display.";
    self.result.stringValue=@"No estimate yet.";
}
- (void)addPoint:(id)sender {
    if (self.confirmed.state!=NSControlStateValueOn) { self.status.stringValue=@"Confirm the measurement conditions before adding a point."; return; }
    NSMutableDictionary *row=[NSMutableDictionary new];
    for (NSString *k in self.fields) row[k]=self.fields[k].stringValue;
    if (![row[@"radio_unit"] length]) { self.status.stringValue=@"Enter a label identifying this individual radio."; return; }
    row[@"radio_model"]=self.model.titleOfSelectedItem; row[@"carrier_method"]=self.method.titleOfSelectedItem;
    row[@"ptt_confirmed"]=@"1";
    row[@"timestamp"]=[[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    NSError *error=nil;
    if (![self.calibration addMeasurement:row error:&error]) { self.status.stringValue=error.localizedDescription; return; }
    self.confirmed.state=NSControlStateValueOff;
    [self refresh:nil];
    // Select the group containing the added row.
    NSDictionary *last=self.calibration.rows.lastObject;
    for (NSUInteger i=0;i<self.measurementGroups.count;i++) if ([self.measurementGroups[i] containsObject:last]) [self.groupPopup selectItemAtIndex:i];
    [self updateReport:nil];
    self.status.stringValue=[NSString stringWithFormat:@"%lu local measurement(s). Export to keep them.",(unsigned long)self.calibration.rows.count];
    for (NSString *k in @[@"sm_dots",@"rm_power_dots",@"measured_w"]) self.fields[k].stringValue=@"";
}
- (BOOL)confirmReplacement {
    if (!self.calibration.rows.count) return YES;
    NSAlert *a=[NSAlert new]; a.messageText=@"Replace this measurement session?";
    a.informativeText=@"Export first if you need to keep the current measurements.";
    [a addButtonWithTitle:@"Cancel"]; [a addButtonWithTitle:@"Replace"];
    return [a runModal]==NSAlertSecondButtonReturn;
}
- (void)importCSV:(id)sender {
    NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.allowedContentTypes=@[UTTypeCommaSeparatedText];
    panel.allowsMultipleSelection=NO;
    if ([panel runModal]!=NSModalResponseOK) return;
    // Read only a bounded prefix, including one extra byte to detect oversized input.
    NSInputStream *stream=[NSInputStream inputStreamWithURL:panel.URL]; [stream open];
    NSMutableData *data=[NSMutableData new]; uint8_t buffer[8192];
    while (data.length<=2*1024*1024) {
        NSInteger n=[stream read:buffer maxLength:MIN(sizeof(buffer),2*1024*1024+1-data.length)];
        if (n<0) { self.status.stringValue=stream.streamError.localizedDescription ?: @"Cannot read CSV."; [stream close]; return; }
        if (!n) break;
        [data appendBytes:buffer length:(NSUInteger)n];
    }
    [stream close];
    TX500PowerCalibration *pending=[TX500PowerCalibration new]; NSError *error=nil;
    if (![pending importCSVData:data error:&error]) { self.status.stringValue=error.localizedDescription; return; }
    if (![self confirmReplacement]) return;
    self.calibration=pending; [self refresh:nil];
    self.status.stringValue=[NSString stringWithFormat:@"Imported %lu real measurements; excluded %lu simulated / empty-watt rows. Export to keep this session.",
        (unsigned long)pending.rows.count,(unsigned long)pending.skippedRows];
}
- (void)exportCSV:(id)sender {
    if (!self.calibration.rows.count) { self.status.stringValue=@"No measurements to export."; return; }
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.allowedContentTypes=@[UTTypeCommaSeparatedText];
    panel.nameFieldStringValue=@"tx500_power_measurements.csv";
    if ([panel runModal]!=NSModalResponseOK) return;
    NSError *error=nil;
    BOOL ok=[[self.calibration CSVData] writeToURL:panel.URL options:NSDataWritingAtomic error:&error];
    self.status.stringValue=ok ? @"Measurements exported. Spreadsheet formulas in text fields are escaped." : error.localizedDescription;
}
- (void)lookup:(id)sender {
    NSScanner *scan=[NSScanner scannerWithString:self.lookupDots.stringValue];
    scan.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; scan.charactersToBeSkipped=nil;
    double dots;
    NSNumber *w=[scan scanDouble:&dots] && scan.isAtEnd ?
        [TX500PowerCalibration estimatedWattsForDots:dots rows:[self selectedRows] meter:[self meterKey]] : nil;
    self.result.stringValue=w ? [NSString stringWithFormat:@"≈ %.3f W (table estimate)",w.doubleValue] :
        @"Unavailable: invalid dots, insufficient / inconsistent data, or outside measured range.";
}
- (void)exportReport:(id)sender {
    if (![self selectedRows].count) { self.status.stringValue=@"Choose measurements to analyse first."; return; }
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.allowedContentTypes=@[UTTypePlainText];
    panel.nameFieldStringValue=@"tx500_power_analysis.txt";
    if ([panel runModal]!=NSModalResponseOK) return;
    NSError *error=nil;
    BOOL ok=[self.report.string writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
    self.status.stringValue=ok ? @"Selected group's analysis exported." : error.localizedDescription;
}
- (void)clear:(id)sender {
    if (![self confirmReplacement]) return;
    self.calibration=[TX500PowerCalibration new]; [self refresh:nil];
    self.status.stringValue=@"New local session. Export measurements to keep them.";
}
@end
