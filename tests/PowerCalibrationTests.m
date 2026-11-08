#import <Cocoa/Cocoa.h>
#import "TX500PowerCalibration.h"
#import "TX500PowerCalibrationController.h"
#import "TX500TelemetryEngine.h"
#import "Lab599TelemetryController.h"
#import <math.h>

@interface TX500PowerCalibrationController (Testing)
- (void)addPoint:(id)sender;
- (void)lookup:(id)sender;
@end
@interface Lab599TelemetryController (Testing)
- (void)openPowerCalibration:(id)sender;
@end

static void Check(BOOL ok, NSString *message) { if (!ok) { NSLog(@"FAIL: %@",message); exit(1); } }
static NSMutableDictionary *Row(NSString *dots, NSString *watts) {
    return [@{@"timestamp":@"2026-10-25T10:00:00Z",@"callsign":@"TEST",@"radio_unit":@"Bench radio A",
        @"radio_model":@"TX-500",@"firmware":@"1.30.00",@"instrument":@"Bench wattmeter",
        @"supply_voltage_v":@"13.8",@"freq_hz":@"14045000",@"band":@"20m",@"carrier_method":@"dig",
        @"pc_set":@"50",@"pc_readback":@"50",@"ptt_confirmed":@"1",@"sm_dots":dots,
        @"rm_power_dots":dots,@"measured_w":watts,@"notes":@"Actual external observation"} mutableCopy];
}
static BOOL Add(TX500PowerCalibration *c, NSDictionary *r) { return [c addMeasurement:r error:NULL]; }
static NSString *CSV(TX500PowerCalibration *c) { return [[NSString alloc] initWithData:c.CSVData encoding:NSUTF8StringEncoding]; }

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        TX500PowerCalibration *c=[TX500PowerCalibration new];
        Check(Add(c,Row(@"5.5",@"1")) && Add(c,Row(@"15.5",@"3")) && Add(c,Row(@"25.5",@"5")),@"Real fractional meter points accepted");
        NSArray *g=c.groups.firstObject;
        Check(fabs([TX500PowerCalibration estimatedWattsForDots:10.5 rows:g meter:@"sm_dots"].doubleValue-2)<1e-9,@"Interpolation keeps fractional medians");
        Check(![TX500PowerCalibration estimatedWattsForDots:5 rows:g meter:@"sm_dots"] &&
              ![TX500PowerCalibration estimatedWattsForDots:26 rows:g meter:@"sm_dots"],@"No extrapolation below or above measured range");
        Check(![TX500PowerCalibration estimatedWattsForDots:NAN rows:g meter:@"sm_dots"],@"NaN lookup rejected");
        Check([[TX500PowerCalibration reportForRows:g meter:@"sm_dots"] containsString:@"Consistent with a linear scale"],@"Measured linear scale recognised with three points");
        Check([[TX500PowerCalibration reportForRows:g meter:@"sm_dots"] containsString:@"PC setpoint"],@"PC comparison table included");
        for (NSString *k in @[@"radio_model",@"firmware",@"carrier_method",@"freq_hz",@"supply_voltage_v",@"callsign",@"radio_unit",@"instrument"]) {
            NSMutableDictionary *r=Row(@"15.5",@"3");
            NSDictionary *alternatives=@{@"radio_model":@"TX-500MP",@"firmware":@"1.29.06",@"carrier_method":@"cg",
                @"freq_hz":@"14046000",@"supply_voltage_v":@"10",@"callsign":@"OTHER",@"radio_unit":@"Bench B",@"instrument":@"Other meter"};
            r[k]=alternatives[k]; Check(Add(c,r),@"Separate conditions accepted");
        }
        Check(c.groups.count==9,@"All eight measurement context dimensions remain isolated");
        for (NSArray *edit in @[@[@"measured_w",@"nan"],@[@"measured_w",@"inf"],@[@"measured_w",@"-1"],
            @[@"measured_w",@"51"],@[@"supply_voltage_v",@"0"],@[@"sm_dots",@"31"],@[@"sm_dots",@"1e1"],
            @[@"pc_readback",@"40"],@[@"ptt_confirmed",@"0"],@[@"notes",@"[simulated]"],@[@"freq_hz",@"27000000"],
            @[@"band",@"40m"],@[@"firmware",@""],@[@"instrument",@""],@[@"carrier_method",@"unknown"]]) {
            NSMutableDictionary *r=Row(@"10",@"2"); r[edit[0]]=edit[1];
            Check(!Add(c,r),[NSString stringWithFormat:@"Invalid %@=%@ rejected",edit[0],edit[1]]);
        }
        TX500PowerCalibration *copy=[TX500PowerCalibration new];
        Check([copy importCSVData:c.CSVData error:NULL] && copy.rows.count==c.rows.count,@"CSV round-trip");
        NSString *original=CSV(copy);
        Check(![copy importCSVData:[@"bad,header\n1,2\n" dataUsingEncoding:NSUTF8StringEncoding] error:NULL] &&
              [CSV(copy) isEqual:original],@"Failed imports preserve existing data");
        for (NSString *bad in @[@"a,a\n1,2",@"a,b\n\"unclosed",@"a,b\n\"closed\"x,2",@"a,b\nquote\"x,2"]) {
            Check(![copy importCSVData:[bad dataUsingEncoding:NSUTF8StringEncoding] error:NULL],@"Malformed CSV rejected");
        }
        Check(![copy importCSVData:[NSMutableData dataWithLength:2*1024*1024+1] error:NULL],@"Oversized data rejected");
        uint8_t invalid[]={0xff,0xfe};
        Check(![copy importCSVData:[NSData dataWithBytes:invalid length:2] error:NULL],@"Invalid UTF8 rejected");
        TX500PowerCalibration *quoted=[TX500PowerCalibration new];
        NSMutableDictionary *q=Row(@"10",@"2"); q[@"instrument"]=@"Meter, \"A\""; q[@"notes"]=@" =HYPERLINK(\"bad\")";
        Check(Add(quoted,q) && [copy importCSVData:quoted.CSVData error:NULL],@"Quoted commas and escaped quotes round-trip");
        Check([copy.rows[0][@"instrument"] isEqual:q[@"instrument"]] && [copy.rows[0][@"notes"] hasPrefix:@"'"],@"Spreadsheet formulas neutralised in export");
        // Use a clean real row for simulator exclusion, independently of formula escaping.
        TX500PowerCalibration *one=[TX500PowerCalibration new]; Check(Add(one,Row(@"10",@"2")),@"One point");
        NSString *sim=[CSV(one) stringByReplacingOccurrencesOfString:@"Actual external observation" withString:@"[SIMULATED]"];
        Check(![copy importCSVData:[sim dataUsingEncoding:NSUTF8StringEncoding] error:NULL],@"All-simulator CSV cannot calibrate watts");
        NSString *two=[CSV(one) stringByAppendingString:[[sim componentsSeparatedByString:@"\r\n"] objectAtIndex:1]];
        Check([copy importCSVData:[two dataUsingEncoding:NSUTF8StringEncoding] error:NULL] && copy.rows.count==1 && copy.skippedRows==1,@"Mixed data excludes simulator rows");
        NSString *bom=[@"\uFEFF" stringByAppendingString:CSV(one)];
        Check([copy importCSVData:[bom dataUsingEncoding:NSUTF8StringEncoding] error:NULL],@"UTF8 BOM accepted");
        NSString *legacy=[[CSV(one) stringByReplacingOccurrencesOfString:@",radio_unit\r\n" withString:@"\r\n"]
            stringByReplacingOccurrencesOfString:@",\"Bench radio A\"\r\n" withString:@"\r\n"];
        Check([copy importCSVData:[legacy dataUsingEncoding:NSUTF8StringEncoding] error:NULL] &&
              [copy.rows.firstObject[@"radio_unit"] isEqual:@""],@"Original 19-column CSV remains compatible without inventing radio identity");
        NSMutableString *wide=[NSMutableString new];
        for (int i=0;i<65;i++) [wide appendFormat:@"%@c%d",i ? @"," : @"",i];
        Check(![copy importCSVData:[wide dataUsingEncoding:NSUTF8StringEncoding] error:NULL],@"Column cap enforced");
        NSString *oversizedField=[@"callsign\n" stringByAppendingString:[@"x" stringByPaddingToLength:1025 withString:@"x" startingAtIndex:0]];
        Check(![copy importCSVData:[oversizedField dataUsingEncoding:NSUTF8StringEncoding] error:NULL],@"Field cap enforced");
        NSMutableString *tooMany=[NSMutableString stringWithString:@"a\n"];
        for (int i=0;i<10001;i++) [tooMany appendString:@"1\n"];
        NSError *limitError=nil;
        Check(![copy importCSVData:[tooMany dataUsingEncoding:NSUTF8StringEncoding] error:&limitError] &&
              [limitError.localizedDescription containsString:@"10,000"],@"Row cap enforced before schema validation");
        // Short deterministic malformed-input corpus, including control bytes and quotes.
        uint32_t seed=42;
        for (int i=0;i<500;i++) {
            NSMutableData *bytes=[NSMutableData new];
            for (int j=0;j<96;j++) { seed=1664525*seed+1013904223; uint8_t b=(seed>>24)&127; [bytes appendBytes:&b length:1]; }
            [copy importCSVData:bytes error:NULL];
        }
        TX500PowerCalibration *bounded=[TX500PowerCalibration new];
        NSMutableDictionary *bulky=Row(@"10",@"2");
        bulky[@"notes"]=[@"\"" stringByPaddingToLength:1024 withString:@"\"" startingAtIndex:0];
        NSUInteger added=0;
        while (added<2000 && Add(bounded,bulky)) added++;
        Check(added>0 && added<2000 && bounded.CSVData.length<=2*1024*1024,
              @"Canonical export size is bounded even with escaped quotes");
        Check([copy importCSVData:bounded.CSVData error:NULL] && copy.rows.count==added,
              @"A full native measurement export remains re-importable");
        TX500PowerCalibration *falling=[TX500PowerCalibration new];
        Check(Add(falling,Row(@"5",@"3")) && Add(falling,Row(@"10",@"1")),@"Inconsistent observations kept for diagnosis");
        Check(![TX500PowerCalibration estimatedWattsForDots:7 rows:falling.rows meter:@"rm_power_dots"],@"Non-monotonic data blocks conversion");
        Check([[TX500PowerCalibration reportForRows:falling.rows meter:@"rm_power_dots"] containsString:@"NON-MONOTONIC"],@"Bad scale prominently identified");
        Check(![TX500PowerCalibration estimatedWattsForDots:10 rows:one.rows meter:@"sm_dots"],@"One point cannot establish a scale");
        TX500PowerCalibration *duplicates=[TX500PowerCalibration new];
        Check(Add(duplicates,Row(@"5",@"1")) && Add(duplicates,Row(@"5",@"3")) && Add(duplicates,Row(@"15",@"4")),@"Repeated dots accepted");
        Check(fabs([TX500PowerCalibration estimatedWattsForDots:10 rows:duplicates.rows meter:@"sm_dots"].doubleValue-3)<1e-9,@"Repeated dots averaged");

        // Instantiate the real UI and exercise its manual workflow. No radio is opened.
        [NSApplication sharedApplication];
        TX500PowerCalibrationController *ui=[TX500PowerCalibrationController new];
        NSDictionary *fields=[ui valueForKey:@"fields"];
        NSButton *confirm=[ui valueForKey:@"confirmed"];
        [ui addPoint:nil];
        Check([[ui valueForKey:@"calibration"] rows].count==0,@"Unchecked confirmation blocks manual entry");
        for (int i=0;i<3;i++) {
            NSDictionary *r=Row([NSString stringWithFormat:@"%d",5+i*10],[NSString stringWithFormat:@"%d",1+i*2]);
            for (NSString *k in fields) [fields[k] setStringValue:r[k] ?: @""];
            confirm.state=NSControlStateValueOn;
            [ui addPoint:nil];
        }
        Check([[ui valueForKey:@"calibration"] rows].count==3 && confirm.state==NSControlStateValueOff,@"UI adds points and requires new confirmation each time");
        NSTextField *lookup=[ui valueForKey:@"lookupDots"]; lookup.stringValue=@"10";
        [ui lookup:nil];
        Check([[[ui valueForKey:@"result"] stringValue] containsString:@"2.000 W"],@"UI lookup displays table estimate");
        Lab599TelemetryController *telemetry=[Lab599TelemetryController new];
        [telemetry openPowerCalibration:nil];
        Check([telemetry valueForKey:@"powerCalibration"]!=nil && !telemetry.engine.isRunning,@"Telemetry opens offline calibration without starting CAT");
        [[[telemetry valueForKey:@"powerCalibration"] window] orderOut:nil];
        if (argc>1 && !strcmp(argv[1],"--preview")) {
            [ui.window orderFront:nil]; [ui.window.contentView layoutSubtreeIfNeeded];
            NSView *view=ui.window.contentView;
            NSBitmapImageRep *rep=[view bitmapImageRepForCachingDisplayInRect:view.bounds];
            [view cacheDisplayInRect:view.bounds toBitmapImageRep:rep];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/power-review/calibration-preview.png" atomically:YES];
        }
        [ui.window orderOut:nil];
        printf("PASS: power calibration validation, CSV safety, interpolation, context isolation and offline UI.\n");
    }
    return 0;
}
