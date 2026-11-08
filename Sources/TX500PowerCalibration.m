#import "TX500PowerCalibration.h"
#import <math.h>

static const NSUInteger MaxBytes = 2 * 1024 * 1024, MaxRows = 10000;
static NSString *CSVCell(NSString *s);
static NSArray<NSString *> *Columns(void) {
    return @[@"timestamp", @"callsign", @"radio_model", @"firmware", @"supply_voltage_v",
        @"vl_raw", @"freq_hz", @"band", @"carrier_method", @"pc_set", @"pc_readback",
        @"sm_dots", @"rm_power_dots", @"rm_swr_dots", @"ptt_confirmed", @"measured_w",
        @"measured_dbm", @"instrument", @"notes", @"radio_unit"];
}
static BOOL Fail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"TX500PowerCalibration" code:1
        userInfo:@{NSLocalizedDescriptionKey:message}];
    return NO;
}
static BOOL Number(NSString *s, double lo, double hi, double *value) {
    if (![s isKindOfClass:NSString.class] || !s.length || s.length > 32) return NO;
    if ([s rangeOfString:@"^(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)$" options:NSRegularExpressionSearch].location==NSNotFound) return NO;
    NSScanner *scan = [NSScanner scannerWithString:s];
    scan.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    scan.charactersToBeSkipped = nil;
    double n;
    if (![scan scanDouble:&n] || !scan.isAtEnd || !isfinite(n) || n < lo || n > hi) return NO;
    if (value) *value = n;
    return YES;
}
static BOOL Integer(NSString *s, double lo, double hi) {
    double n;
    return Number(s, lo, hi, &n) && trunc(n) == n;
}
static NSString *Band(double hz) {
    const double edges[][2] = {{1800000,2000000},{3500000,4000000},{5351500,5366500},
        {7000000,7300000},{10100000,10150000},{14000000,14350000},{18068000,18168000},
        {21000000,21450000},{24890000,24990000},{28000000,29700000},{50000000,54000000}};
    NSArray *names = @[@"160m",@"80m",@"60m",@"40m",@"30m",@"20m",@"17m",@"15m",@"12m",@"10m",@"6m"];
    for (NSUInteger i=0; i<names.count; i++) if (hz >= edges[i][0] && hz <= edges[i][1]) return names[i];
    return nil; // Measurement classification, never a transmission permission.
}

// Bounded RFC4180-style parser, including quoted commas, newlines and escaped quotes.
static NSArray *ParseCSV(NSString *text, NSError **error) {
    NSMutableArray *records = [NSMutableArray new], *record = [NSMutableArray new];
    NSMutableString *field = [NSMutableString new];
    BOOL quoted = NO, closed = NO, started = NO;
    for (NSUInteger i=0; i<=text.length; i++) {
        unichar c = i<text.length ? [text characterAtIndex:i] : '\n';
        if (quoted) {
            if (i == text.length) { Fail(error,@"Unclosed CSV quote."); return nil; }
            if (c == '"') {
                if (i+1<text.length && [text characterAtIndex:i+1]=='"') { [field appendString:@"\""]; i++; }
                else { quoted=NO; closed=YES; }
            } else [field appendFormat:@"%C",c];
        } else if (c=='"' && !started && !closed) { quoted=YES; started=YES; }
        else if (c==',' || c=='\n' || c=='\r') {
            [record addObject:[field copy]];
            if (record.count>64) { Fail(error,@"Too many CSV columns."); return nil; }
            [field setString:@""]; started=NO; closed=NO;
            if (c!=',') {
                if (record.count>1 || [record.firstObject length]) [records addObject:[record copy]];
                [record removeAllObjects];
                if (records.count>MaxRows+1) { Fail(error,@"CSV exceeds 10,000 measurements."); return nil; }
                if (c=='\r' && i+1<text.length && [text characterAtIndex:i+1]=='\n') i++;
            }
        } else {
            if (closed || c=='"' || c==0) { Fail(error,@"Invalid CSV field."); return nil; }
            [field appendFormat:@"%C",c]; started=YES;
        }
        if (field.length>1024) { Fail(error,@"CSV field exceeds 1,024 characters."); return nil; }
    }
    return records;
}

static BOOL ValidRow(NSDictionary *r, NSError **error) {
    for (id k in r) {
        id v = r[k];
        if (![k isKindOfClass:NSString.class] || ![v isKindOfClass:NSString.class] || [v length]>1024 ||
            [v rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)
            return Fail(error,@"Measurement fields must be short text without control characters.");
    }
    for (NSString *k in @[@"radio_model",@"firmware",@"instrument",@"callsign"])
        if (![r[k] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length)
            return Fail(error,[NSString stringWithFormat:@"Missing %@.",k]);
    if (![@[@"TX-500",@"TX-500 Discovery",@"TX-500MP",@"TX-500PRO",@"TX-500PRO ALTAI"] containsObject:r[@"radio_model"]])
        return Fail(error,@"Unknown radio model.");
    if (![@[@"cg",@"tone",@"cw",@"dig"] containsObject:r[@"carrier_method"]])
        return Fail(error,@"Unknown carrier method.");
    if (![r[@"ptt_confirmed"] isEqual:@"1"] || !Integer(r[@"pc_set"],10,100) ||
        !Integer(r[@"pc_readback"],10,100) || [r[@"pc_set"] integerValue]!=[r[@"pc_readback"] integerValue])
        return Fail(error,@"Measurement needs confirmed TX and matching PC set/read-back (10–100).");
    if (!Integer(r[@"freq_hz"],1800000,54000000) ||
        ![Band([r[@"freq_hz"] doubleValue]) isEqual:r[@"band"]])
        return Fail(error,@"Frequency and band do not match.");
    if (!Number(r[@"supply_voltage_v"],9,15,NULL) || !Number(r[@"measured_w"],0,50,NULL))
        return Fail(error,@"Enter finite measured watts (0–50) and supply voltage (9–15 V).");
    BOOL hasMeter = NO;
    for (NSString *k in @[@"sm_dots",@"rm_power_dots"]) {
        if ([r[k] length]) {
            if (!Number(r[k],0,30,NULL)) return Fail(error,@"Meter dots must be finite and between 0 and 30.");
            hasMeter=YES;
        }
    }
    if (!hasMeter) return Fail(error,@"At least one TX power meter reading is required.");
    if ([r[@"notes"] length] && [r[@"notes"] rangeOfString:@"[SIMULATED]" options:NSCaseInsensitiveSearch].location!=NSNotFound)
        return Fail(error,@"Simulated data cannot calibrate real watts.");
    return YES;
}

@implementation TX500PowerCalibration {
    NSMutableArray<NSDictionary<NSString *,NSString *> *> *_measurements;
    NSUInteger _skippedRows;
    NSUInteger _CSVByteCount;
}
- (instancetype)init {
    if ((self=[super init])) {
        _measurements=[NSMutableArray new];
        _CSVByteCount=[[Columns() componentsJoinedByString:@","] lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+2;
    }
    return self;
}
- (NSArray *)rows { return [_measurements copy]; }
- (NSUInteger)skippedRows { return _skippedRows; }
- (BOOL)addMeasurement:(NSDictionary *)row error:(NSError **)error {
    if (_measurements.count>=MaxRows) return Fail(error,@"Maximum 10,000 measurements per session.");
    if (!ValidRow(row,error)) return NO;
    NSMutableDictionary *clean = [NSMutableDictionary new];
    for (NSString *k in Columns()) clean[k]=[row[k] copy] ?: @"";
    clean[@"measured_dbm"]=[row[@"measured_w"] doubleValue]>0 ?
        [NSString stringWithFormat:@"%.5f",10*log10([row[@"measured_w"] doubleValue]*1000)] : @"";
    NSUInteger rowBytes=Columns().count-1+2;
    for (NSString *k in Columns()) rowBytes+=[CSVCell(clean[k]) lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    if (_CSVByteCount+rowBytes>MaxBytes) return Fail(error,@"Measurement session exceeds 2 MiB when exported.");
    [_measurements addObject:[clean copy]];
    _CSVByteCount+=rowBytes;
    return YES;
}
- (BOOL)importCSVData:(NSData *)data error:(NSError **)error {
    if (!data.length || data.length>MaxBytes) return Fail(error,@"CSV must be between 1 byte and 2 MiB.");
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return Fail(error,@"CSV must use UTF-8.");
    if ([text hasPrefix:@"\uFEFF"]) text=[text substringFromIndex:1];
    NSArray *records=ParseCSV(text,error);
    if (!records) return NO;
    if (!records.count) return Fail(error,@"Empty CSV.");
    NSArray *header=records[0];
    if ([NSSet setWithArray:header].count!=header.count) return Fail(error,@"Duplicate CSV column.");
    for (NSString *k in @[@"callsign",@"radio_model",@"firmware",@"supply_voltage_v",@"freq_hz",@"band",
        @"carrier_method",@"pc_set",@"pc_readback",@"ptt_confirmed",@"measured_w",@"instrument",@"notes"])
        if (![header containsObject:k]) return Fail(error,[NSString stringWithFormat:@"Missing CSV column: %@",k]);
    if (![header containsObject:@"sm_dots"] && ![header containsObject:@"rm_power_dots"])
        return Fail(error,@"Missing power-meter column.");
    TX500PowerCalibration *pending=[TX500PowerCalibration new];
    NSUInteger skipped=0;
    for (NSUInteger i=1; i<records.count; i++) {
        NSArray *cells=records[i];
        if (cells.count!=header.count) return Fail(error,[NSString stringWithFormat:@"CSV row %lu has a wrong column count.",(unsigned long)i+1]);
        NSMutableDictionary *row=[NSMutableDictionary new];
        for (NSUInteger j=0;j<header.count;j++) row[header[j]]=cells[j];
        if ([row[@"notes"] rangeOfString:@"[SIMULATED]" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
            ![row[@"measured_w"] length]) { skipped++; continue; }
        NSError *rowError=nil;
        if (![pending addMeasurement:row error:&rowError])
            return Fail(error,[NSString stringWithFormat:@"CSV row %lu: %@",(unsigned long)i+1,rowError.localizedDescription]);
    }
    if (!pending.rows.count) return Fail(error,@"No real measured rows. Simulated and empty-watt rows are excluded.");
    // Atomic replacement: a malformed import never damages the current session.
    _measurements=[pending.rows mutableCopy]; _skippedRows=skipped; _CSVByteCount=pending->_CSVByteCount;
    return YES;
}
- (NSArray *)groups {
    NSMutableDictionary<NSArray *,NSMutableArray *> *grouped=[NSMutableDictionary new];
    for (NSDictionary *r in _measurements) {
        // Exact frequency and voltage, as well as unit/author/instrument, are kept separate.
        NSArray *key=@[r[@"radio_model"],r[@"firmware"],r[@"carrier_method"],r[@"band"],
            @([r[@"freq_hz"] doubleValue]),@([r[@"supply_voltage_v"] doubleValue]),
            r[@"callsign"],r[@"radio_unit"],r[@"instrument"]];
        if (!grouped[key]) grouped[key]=[NSMutableArray new];
        [grouped[key] addObject:r];
    }
    return [[grouped allValues] sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[TX500PowerCalibration groupTitle:a] compare:[TX500PowerCalibration groupTitle:b] options:NSLiteralSearch];
    }];
}
+ (NSString *)groupTitle:(NSArray *)rows {
    NSDictionary *r=rows.firstObject;
    return [NSString stringWithFormat:@"%@ • fw %@ • %@ • %@ Hz • %@ V • %@ • %@ • %@ • %@",
        r[@"radio_model"] ?: @"",r[@"firmware"] ?: @"",r[@"band"] ?: @"",r[@"freq_hz"] ?: @"",
        r[@"supply_voltage_v"] ?: @"",r[@"carrier_method"] ?: @"",r[@"callsign"] ?: @"",
        [r[@"radio_unit"] length] ? r[@"radio_unit"] : @"unit unspecified",r[@"instrument"] ?: @""];
}
static NSArray<NSArray<NSNumber *> *> *Points(NSArray *rows, NSString *meter) {
    if (![@[@"sm_dots",@"rm_power_dots"] containsObject:meter]) return @[];
    NSMutableDictionary<NSNumber *,NSMutableArray *> *buckets=[NSMutableDictionary new];
    for (NSDictionary *r in rows) if ([r[meter] length]) {
        NSNumber *d=@([r[meter] doubleValue]);
        if (!buckets[d]) buckets[d]=[NSMutableArray new];
        [buckets[d] addObject:@([r[@"measured_w"] doubleValue])];
    }
    NSMutableArray *out=[NSMutableArray new];
    for (NSNumber *d in [[buckets allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        double sum=0; for (NSNumber *w in buckets[d]) sum+=w.doubleValue;
        [out addObject:@[d,@(sum/buckets[d].count)]];
    }
    return out;
}
static BOOL Monotonic(NSArray *points) {
    for (NSUInteger i=1;i<points.count;i++) if ([points[i][1] doubleValue]<[points[i-1][1] doubleValue]) return NO;
    return YES;
}
+ (NSNumber *)estimatedWattsForDots:(double)dots rows:(NSArray *)rows meter:(NSString *)meter {
    NSArray *p=Points(rows,meter);
    if (!isfinite(dots) || p.count<2 || !Monotonic(p) || dots<[p[0][0] doubleValue] || dots>[p.lastObject[0] doubleValue]) return nil;
    for (NSUInteger i=1;i<p.count;i++) {
        double x0=[p[i-1][0] doubleValue], x1=[p[i][0] doubleValue];
        if (dots<=x1) {
            double y0=[p[i-1][1] doubleValue], y1=[p[i][1] doubleValue];
            return @(y0+(y1-y0)*(dots-x0)/(x1-x0));
        }
    }
    return nil;
}
+ (NSString *)reportForRows:(NSArray *)rows meter:(NSString *)meter {
    NSArray *p=Points(rows,meter);
    NSMutableString *s=[NSMutableString stringWithFormat:@"%@\n\nMeter: %@. %lu rows; %lu distinct dot values.\n",
        [self groupTitle:rows],meter,(unsigned long)rows.count,(unsigned long)p.count];
    [s appendString:@"External wattmeter readings; table values are estimates for the reported conditions only.\nCallsigns do not identify individual radios. No table is applied automatically to live telemetry.\n\n"];
    if (![rows.firstObject[@"radio_unit"] length]) [s appendString:@"Unit unspecified: this is exploratory data, not calibration of an identified physical radio.\n\n"];
    if (p.count<2) { [s appendString:@"Add at least two distinct dot values to interpolate.\n"]; return s; }
    if (!Monotonic(p)) [s appendString:@"NON-MONOTONIC: more dots give fewer watts. Lookup disabled; check measurements.\n"];
    double mx=0,my=0,n=0;
    for (NSDictionary *r in rows) if ([r[meter] length]) { mx+=[r[meter] doubleValue]; my+=[r[@"measured_w"] doubleValue]; n++; }
    mx/=n; my/=n;
    double xx=0,xy=0,total=0,residual=0,err=0;
    for (NSDictionary *r in rows) if ([r[meter] length]) {
        double x=[r[meter] doubleValue]-mx,y=[r[@"measured_w"] doubleValue]-my;
        xx+=x*x; xy+=x*y; total+=y*y;
    }
    double a=xy/xx,b=my-a*mx;
    for (NSDictionary *r in rows) if ([r[meter] length]) {
        double y=[r[@"measured_w"] doubleValue],e=fabs(y-a*[r[meter] doubleValue]-b);
        residual+=e*e; err=fmax(err,y>0 ? e/y : (e>1e-9 ? INFINITY : 0));
    }
    double r2=total>0 ? 1-residual/total : 0;
    [s appendFormat:@"Fit: W = %.5f × dots %+.5f; R² %.5f; max relative error %.1f%%.\n",a,b,r2,err*100];
    [s appendFormat:@"%@\n\n",p.count>=3 && a>0 && Monotonic(p) && r2>=0.98 && err<=0.10 ?
        @"Consistent with a linear scale within these observations (not hardware validation)." :
        @"Linearity not established. Use only the measured-range interpolation if monotonic."];
    [s appendString:@"Measured points (repeated dots averaged):\nDots       Mean W\n"];
    for (NSArray *point in p) [s appendFormat:@"%6.2f     %8.3f\n",[point[0] doubleValue],[point[1] doubleValue]];
    NSMutableDictionary<NSNumber *,NSMutableArray *> *pcGroups=[NSMutableDictionary new];
    for (NSDictionary *r in rows) {
        NSNumber *pc=@([r[@"pc_set"] integerValue]);
        if (!pcGroups[pc]) pcGroups[pc]=[NSMutableArray new];
        [pcGroups[pc] addObject:@([r[@"measured_w"] doubleValue])];
    }
    [s appendString:@"\nPC setpoint     Mean measured W     Samples\n"];
    for (NSNumber *pc in [[pcGroups allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        double sum=0; for (NSNumber *w in pcGroups[pc]) sum+=w.doubleValue;
        [s appendFormat:@"%3ld             %8.3f            %lu\n",(long)pc.integerValue,sum/pcGroups[pc].count,(unsigned long)pcGroups[pc].count];
    }
    if (Monotonic(p)) {
        [s appendString:@"\nInterpolation table — no extrapolation:\nDots       W estimate       dBm\n"];
        for (NSInteger d=0;d<=30;d++) {
            NSNumber *w=[self estimatedWattsForDots:d rows:rows meter:meter];
            if (w) [s appendFormat:@"%2ld         %8.3f          %@\n",(long)d,w.doubleValue,
                w.doubleValue>0 ? [NSString stringWithFormat:@"%.2f",10*log10(w.doubleValue*1000)] : @"undefined"];
        }
    }
    return s;
}
static NSString *CSVCell(NSString *s) {
    // Quoting alone does not prevent spreadsheet formula execution.
    NSString *trim=[s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trim.length && [@"=+-@" rangeOfString:[trim substringToIndex:1]].location!=NSNotFound) s=[@"'" stringByAppendingString:s];
    return [NSString stringWithFormat:@"\"%@\"",[s stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}
- (NSData *)CSVData {
    NSMutableString *s=[NSMutableString stringWithFormat:@"%@\r\n",[Columns() componentsJoinedByString:@","]];
    for (NSDictionary *r in _measurements) {
        NSMutableArray *cells=[NSMutableArray new];
        for (NSString *k in Columns()) [cells addObject:CSVCell(r[k] ?: @"")];
        [s appendFormat:@"%@\r\n",[cells componentsJoinedByString:@","]];
    }
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}
@end
