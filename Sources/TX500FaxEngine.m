// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500FaxEngine.h"
#import "TX500SSTVEngine.h"            // the WAV reader's reasons in English (N2-fax-app-17)
#include "sstv1/sstv1.h"
#include "sstv1/wav.h"

static NSError *FaxError(NSInteger code, NSString *text) {
    return [NSError errorWithDomain:@"TX500FaxErrorDomain" code:code userInfo:@{NSLocalizedDescriptionKey: text}];
}

static NSString *FaxNoteName(wefax_note n) {
    switch (n) {
    case WEFAX_NOTE_PHASING_UNRELIABLE: return @"phasing_unreliable";
    case WEFAX_NOTE_DEVIATION_DIFFERS: return @"deviation_differs";
    case WEFAX_NOTE_NO_LINES: return @"no_lines";
    case WEFAX_NOTE_NO_MEMORY: return @"no_memory";
    case WEFAX_NOTE_INVERTED_WHITE_FIRST: return @"inverted_white_first";
    case WEFAX_NOTE_POLARITY_UNDECIDED: return @"polarity_undecided";
    case WEFAX_NOTE_INVERTED_UNDECIDED: return @"inverted_undecided";
    case WEFAX_NOTE_DEAD_SECTOR_ELSEWHERE: return @"dead_sector_elsewhere";
    case WEFAX_NOTE_FLDIGI_STYLE: return @"fldigi_style";
    case WEFAX_NOTE_SEAM_MARGIN: return @"seam_margin";
    case WEFAX_NOTE_MARGIN_UNKNOWN: return @"margin_unknown";
    case WEFAX_NOTE_INCOMPLETE: return @"incomplete";
    case WEFAX_NOTE_PHASING_STRICT: return @"phasing_strict";
    case WEFAX_NOTE_LPM_MISMATCH: return @"lpm_mismatch";
    case WEFAX_NOTE_NO_PHASING_AFTER_START: return @"no_phasing_after_start";
    case WEFAX_NOTE_START_IN_PICTURE: return @"start_in_picture";
    case WEFAX_NOTE_ENDS_WITHOUT_STOP: return @"ends_without_stop";
    case WEFAX_NOTE_START_WITHOUT_PICTURE: return @"start_without_picture";
    case WEFAX_NOTE_SIGNAL_LOST: return @"signal_lost";
    case WEFAX_NOTE_SIGNAL_BACK: return @"signal_back";
    case WEFAX_NOTE_CLOSED_BY_START: return @"closed_by_start";
    case WEFAX_NOTE_CLOSED_BY_PHASING: return @"closed_by_phasing";
    case WEFAX_NOTE_LINE_LIMIT: return @"line_limit";
    case WEFAX_NOTE_SEAM_CONFIRMS: return @"seam_confirms";
    case WEFAX_NOTE_NONE: break;
    }
    return @"";
}

@interface TX500FaxChart ()
@property (nonatomic, readwrite) NSInteger index, width, height, phasingKind, phasingLines, lostLines;
@property (nonatomic, readwrite) BOOL complete, phasingInverted, fldigiStyleSeen;
@property (nonatomic, readwrite, copy) NSData *gray;
@property (nonatomic, readwrite) double linePeriodMs, slantPPM, offsetHz, deviationMeasuredHz;
@property (nonatomic, readwrite, copy) NSString *marginSource;
@property (nonatomic, readwrite) NSUInteger decode;
@property (nonatomic, readwrite, copy) NSString *fileName;
@end

@implementation TX500FaxChart
- (NSBitmapImageRep *)bitmap {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:self.width pixelsHigh:self.height
                                                                bitsPerSample:8 samplesPerPixel:1 hasAlpha:NO isPlanar:NO
                                                               colorSpaceName:NSDeviceWhiteColorSpace bytesPerRow:self.width bitsPerPixel:8];
    if (rep && self.gray.length >= (NSUInteger)(self.width * self.height))
        memcpy(rep.bitmapData, self.gray.bytes, (size_t)(self.width * self.height));
    return rep;
}
- (NSImage *)image {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(self.width, self.height)];
    NSBitmapImageRep *rep = [self bitmap];
    if (rep) [img addRepresentation:rep];
    return img;
}
- (BOOL)writePNGToURL:(NSURL *)url error:(NSError **)error {
    NSData *png = [[self bitmap] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) { if (error) *error = FaxError(2, @"The chart could not be made into a PNG."); return NO; }
    return [png writeToURL:url options:NSDataWritingAtomic error:error];
}
@end

@interface TX500FaxNotice ()
@property (nonatomic, readwrite) double time;
@property (nonatomic, readwrite, copy) NSString *text, *note;
@end
@implementation TX500FaxNotice
@end

@implementation TX500FaxEngine {
    wefax_rx *_rx;
    NSMutableArray<TX500FaxChart *> *_charts;
    NSMutableArray<TX500FaxNotice *> *_notices;
    NSUInteger _decodes;
    NSString *_fileName;
}

- (instancetype)init {
    if ((self = [super init])) {
        _deviationHz = 400.0; _lpm = 120.0; _ioc = 576; _width = 0;
        _lineStart = TX500FaxLineStartStandard;
        _charts = [NSMutableArray array];
        _notices = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithPreviousDecodeCount:(NSUInteger)count {
    if((self=[self init])) _decodes=count;
    return self;
}

- (void)dealloc { if (_rx) wefax_rx_free(_rx); }

- (NSArray<TX500FaxChart *> *)charts { return [_charts copy]; }
- (NSArray<TX500FaxNotice *> *)notices { return [_notices copy]; }
- (NSUInteger)decodes { return _decodes; }

+ (NSString *)textForNote:(NSString *)note value:(double)v chosenDeviation:(double)dev chosenLPM:(double)lpm {
    NSDictionary<NSString *, NSString *> *t = @{
        @"phasing_unreliable": @"The phasing cannot be trusted: the chosen tuning and speed are kept, and the margin is not known.",
        @"no_lines": @"A chart with no line of picture: nothing is saved.",
        @"no_memory": @"Not enough memory for the chart.",
        @"inverted_white_first": @"Inverted phasing: the dead sector says the line starts at the white, not at the black; the margin is put there.",
        @"polarity_undecided": @"Symmetric phasing: the dead sector does not tell the polarity; the normal one is taken.",
        @"inverted_undecided": @"Inverted phasing: the dead sector does not tell which edge starts the line; the black one is taken (our convention: no source says).",
        @"margin_unknown": @"No phasing and no dead sector: the margin is not known; move it by hand afterwards, or choose Auto-align.",
        @"incomplete": @"The chart is saved as incomplete.",
        @"phasing_strict": @"Closed at the line limit: until a start or stop signal, only a clear phasing starts the next chart.",
        @"no_phasing_after_start": @"No phasing after the start signal: received without it.",
        @"start_in_picture": @"A short piece of start signal inside the chart: ignored.",
        @"ends_without_stop": @"The signal ends with no stop signal.",
        @"start_without_picture": @"A start signal with no chart after it.",
        @"signal_lost": @"Signal lost: the lines go on in their place, in grey.",
        @"closed_by_start": @"Closed by the next chart's start signal (it had no stop): saved.",
        @"closed_by_phasing": @"Closed by the next chart's phasing (it had no stop): saved.",
        @"line_limit": @"Closed at the line limit: one chart with no stop has 4000 lines at most.",
    };
    if ([note isEqualToString:@"deviation_differs"])
        return [NSString stringWithFormat:@"Deviation measured on the phasing: %.0f Hz; the chosen one is %.0f Hz: the greys may be off (choose the station's deviation).", v, dev];
    if ([note isEqualToString:@"dead_sector_elsewhere"])
        return [NSString stringWithFormat:@"The dead sector is %+.0f points away from where the phasing puts it; the phasing is kept.", v];
    if ([note isEqualToString:@"fldigi_style"])
        return [NSString stringWithFormat:@"The lines start %+.0f points after the phasing edge, as fldigi's do: the standard is kept; choose fldigi or Auto-align for this sender.", v];
    if ([note isEqualToString:@"seam_margin"])
        return [NSString stringWithFormat:@"Margin from the picture's seam: %+.0f points.", v];
    if ([note isEqualToString:@"seam_confirms"])
        return [NSString stringWithFormat:@"The picture's seam confirms where the line starts (%+.0f points).", v];
    if ([note isEqualToString:@"lpm_mismatch"])
        return [NSString stringWithFormat:@"The phasing runs at %.0f LPM, not at the %.0f chosen: the speed does not fit.", v, lpm];
    if ([note isEqualToString:@"signal_back"])
        return [NSString stringWithFormat:@"Signal back: %.1f s lost, in grey.", v];
    return t[note] ?: @"";
}

- (BOOL)decodeFileAtURL:(NSURL *)url error:(NSError **)error {
    wav_reader w;
    char err[256] = {0};
    if (wav_open(&w, url.fileSystemRepresentation, err, sizeof err) != 0) {
        if (error) *error = FaxError(1, [NSString stringWithFormat:@"Cannot read %@: %@.", url.lastPathComponent,
                                         TX500WAVReasonInEnglish(err)]);
        return NO;
    }
    wefax_rx_config cfg;
    wefax_rx_config_default(&cfg);
    cfg.deviation_hz = self.deviationHz;
    cfg.lpm = self.lpm;
    cfg.ioc = (int)self.ioc;
    cfg.width = (int)self.width;
    cfg.line_start = self.lineStart == TX500FaxLineStartFldigi ? WEFAX_LINE_START_FLDIGI :
                     self.lineStart == TX500FaxLineStartAuto ? WEFAX_LINE_START_AUTO : WEFAX_LINE_START_STANDARD;
    cfg.keep_buffers = 1;                      // the margin can be moved afterwards
    // the new receiver first: when it cannot be made, the chart shown and its receiver stay as they were (N2-fax-app-13)
    wefax_rx *rx = wefax_rx_new(w.rate, &cfg);
    if (!rx) {
        wav_close(&w);
        if (error) *error = FaxError(3, [NSString stringWithFormat:@"The fax receiver cannot work at %u Hz.", (unsigned)w.rate]);
        return NO;
    }
    // in blocks of one second, as the command line does (the picture does not depend on it); out of
    // memory is said, never taken for the end of the file (N2-fax-app-3)
    size_t blk = (size_t)(w.rate + 0.5);
    float *buf = malloc(blk * sizeof(float));
    BOOL fed = buf != NULL;
    size_t got;
    double lastProgress=-1;
    while (fed && !self.cancelRequested && (got = wav_read(&w, buf, blk)) > 0) {
        if (wefax_rx_feed(rx, buf, got) != 0) fed = NO;
        double progress=w.frames ? (double)w.pos/w.frames : 1;
        if(self.onDecodeProgress && progress-lastProgress>=0.01) { self.onDecodeProgress(progress); lastProgress=progress; }
    }
    if(self.cancelRequested) {
        free(buf); wav_close(&w); wefax_rx_free(rx);
        if(error) *error=FaxError(6,@"Decode cancelled. The previous chart is unchanged.");
        return NO;
    }
    if (fed && w.pos < w.frames) fed = NO;                 // the reader stopped early: it could not get its memory
    free(buf);
    wav_close(&w);
    if (!fed) {
        wefax_rx_free(rx);
        if (error) *error = FaxError(5, [NSString stringWithFormat:@"Not enough memory to decode %@.", url.lastPathComponent]);
        return NO;
    }
    if (_rx) wefax_rx_free(_rx);
    _rx = rx;
    _decodes++;                                // the charts of an earlier file keep their own number
    _fileName = [url.lastPathComponent copy] ?: @"";
    [_charts removeAllObjects];
    [_notices removeAllObjects];
    wefax_rx_finish(_rx);
    wefax_event e;
    while (wefax_rx_next_event(_rx, &e)) {
        TX500FaxNotice *n = [TX500FaxNotice new];
        n.time = e.t;
        n.note = FaxNoteName(e.note);
        switch (e.type) {
        case WEFAX_EV_START: n.text = [NSString stringWithFormat:@"Start signal at %.0f Hz.", e.value]; break;
        case WEFAX_EV_PHASING: n.text = [NSString stringWithFormat:@"Phasing found: %.4f ms per line.", e.value]; break;
        case WEFAX_EV_STOP: n.text = @"Stop signal."; break;
        case WEFAX_EV_IMAGE: n.text = [NSString stringWithFormat:@"Chart: %.0f lines.", e.value]; break;
        case WEFAX_EV_WARNING:
            n.text = [TX500FaxEngine textForNote:n.note value:e.value chosenDeviation:self.deviationHz chosenLPM:self.lpm];
            // Auto-align is suggested only when it is not the choice already (NUC-10)
            if ([n.note isEqualToString:@"margin_unknown"] && self.lineStart == TX500FaxLineStartAuto)
                n.text = @"No phasing and no dead sector, and the picture's seam does not show where the line starts: the margin is not known; move it by hand afterwards.";
            break;
        }
        if (n.text.length) [_notices addObject:n];
    }
    for (int i = 0; i < wefax_rx_image_count(_rx); i++) [_charts addObject:[self chartAt:i]];
    return YES;
}

- (TX500FaxChart *)chartAt:(int)i {
    const wefax_image *im = wefax_rx_image(_rx, i);
    TX500FaxChart *c = [TX500FaxChart new];
    c.index = i; c.width = im->width; c.height = im->height; c.complete = im->complete != 0;
    c.decode = _decodes; c.fileName = _fileName ?: @"";
    c.gray = im->gray ? [NSData dataWithBytes:im->gray length:(NSUInteger)(im->width * im->height)] : [NSData data];
    c.linePeriodMs = im->line_period_s * 1e3; c.slantPPM = im->slant_ppm; c.offsetHz = im->offset_hz;
    c.deviationMeasuredHz = im->deviation_measured_hz;
    c.phasingKind = im->phasing_found; c.phasingInverted = im->phasing_inverted != 0; c.phasingLines = im->phasing_lines;
    c.fldigiStyleSeen = im->fldigi_style_seen != 0; c.lostLines = im->lost_lines;
    c.marginSource = im->margin_source == 1 ? @"the phasing" : im->margin_source == 2 ? @"the dead sector" :
                     im->margin_source == 3 ? @"the picture's seam" : im->margin_source == 4 ? @"the phasing, fldigi's way" : @"nothing known";
    return c;
}

- (BOOL)moveMarginOfChart:(NSInteger)index byPoints:(double)points {
    if (!_rx || index < 0 || index >= (NSInteger)_charts.count) return NO;
    TX500FaxChart *c = _charts[(NSUInteger)index];
    double ms = c.width > 0 ? points / (double)c.width * c.linePeriodMs : 0.0;
    if (wefax_rx_rerender(_rx, (int)index, 0.0, ms) != 0) return NO;
    _charts[(NSUInteger)index] = [self chartAt:(int)index];
    return YES;
}
@end
