// SPDX-License-Identifier: GPL-3.0-or-later
// Radiofax, files only for now (FX1-FX4, FX30): the core's fax receiver, decoding a WAV file the
// operator opens. Receive only: there is no audio output, no
// CAT and no PTT anywhere in it. A chart is no contact: nothing here ever offers Record QSO, and a
// file is never logged.
#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500FaxLineStart) {
    TX500FaxLineStartStandard = 0,   // the leading edge of the white phasing pulse (WMO), the default
    TX500FaxLineStartFldigi,         // the middle of the phasing band, as fldigi starts its lines
    TX500FaxLineStartAuto            // where the picture's own seam says
};

/// One received chart: grey, width x height, with what the receiver found.
@interface TX500FaxChart : NSObject
@property (nonatomic, readonly) NSInteger index, width, height;
@property (nonatomic, readonly) BOOL complete;
@property (nonatomic, readonly, copy) NSData *gray;
@property (nonatomic, readonly) double linePeriodMs, slantPPM, offsetHz, deviationMeasuredHz;
@property (nonatomic, readonly) NSInteger phasingKind;      // 0 none, 1 5/95, 2 symmetric
@property (nonatomic, readonly) BOOL phasingInverted, fldigiStyleSeen;
@property (nonatomic, readonly) NSInteger phasingLines, lostLines;
/// Where its margin came from, in words: "the phasing", "the dead sector", "the picture's seam",
/// "the phasing, fldigi's way" or "nothing known".
@property (nonatomic, readonly, copy) NSString *marginSource;
/// The decode it came from (the engine's decodes then): its margin can be moved only while it is of
/// the last one, whose samples the receiver still keeps.
@property (nonatomic, readonly) NSUInteger decode;
/// The name of the file it came from.
@property (nonatomic, readonly, copy) NSString *fileName;
/// Its PNG in the Fax folder, once the operator saved it there with «Save to the Fax folder» (nil: not saved).
@property (nonatomic, copy, nullable) NSURL *savedURL;
- (NSBitmapImageRep *)bitmap;
- (NSImage *)image;
- (BOOL)writePNGToURL:(NSURL *)url error:(NSError **)error;
@end

/// What the receiver said, in English for the screen.
@interface TX500FaxNotice : NSObject
@property (nonatomic, readonly) double time;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy) NSString *note;      // the core's note name ("" for none)
@end

@interface TX500FaxEngine : NSObject
@property (nonatomic) double deviationHz;                   // 400 (WMO, HF)
@property (nonatomic) double lpm;                           // 120
@property (nonatomic) NSInteger ioc;                        // 576
@property (nonatomic) NSInteger width;                      // 0 = round(π x IOC): 1810 at IOC 576 (A36)
@property (nonatomic) TX500FaxLineStart lineStart;
@property (nonatomic, readonly, copy) NSArray<TX500FaxChart *> *charts;
@property (nonatomic, readonly, copy) NSArray<TX500FaxNotice *> *notices;
/// How many files it has decoded (a file refused does not count); the charts of the last one carry
/// this number as their decode.
@property (nonatomic, readonly) NSUInteger decodes;
/// Decodes a WAV file, with the settings above (the same as the core's command line: the same
/// picture, bit for bit). Replaces what an earlier file gave.
- (BOOL)decodeFileAtURL:(NSURL *)url error:(NSError **)error;
/// Moves a chart's margin after receiving, from the samples it kept (nothing is lost).
- (BOOL)moveMarginOfChart:(NSInteger)index byPoints:(double)points;
/// The English words for a note of the core (for the tests too).
+ (NSString *)textForNote:(NSString *)note value:(double)value chosenDeviation:(double)dev chosenLPM:(double)lpm;
@end

NS_ASSUME_NONNULL_END
