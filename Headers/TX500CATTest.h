#import <Foundation/Foundation.h>
#import "Lab599SerialPort.h"

typedef NS_ENUM(NSInteger, TXCATCode) {
    TXCATOK = 0, TXCATPortError = 1, TXCATNoReply = 2,
    TXCATWrongLength = 3, TXCATUnexpectedID = 4
};
typedef struct {
    double responseTimeout;
    double cycleInterval;
    double settleDelay;
    NSUInteger maximumChecks; // 0: repeat until cancelled; 1: single check
} TXCATOptions;

FOUNDATION_EXPORT TXCATOptions TXDefaultCATOptions(void);
FOUNDATION_EXPORT TXCATCode TXClassifyCATReply(NSData *reply);
// Display label for an exact, six-character ID; reply. ID500 identifies a
// family, while ID501/ID502 are legacy accepted replies without a known model.
static inline NSString *TXModelNameForIDReply(NSString *reply) {
    // Lab599 CAT Protocol rev. 3 documents 019 (TS2000), 500 (TX-500
    // family) and 505 (TX-500MP). ID501/ID502 are accepted without a model name.
    if ([reply isEqualToString:@"ID019;"]) return @"Lab599 radio, TS2000 protocol (ID019)";
    if ([reply isEqualToString:@"ID500;"]) return @"Lab599 TX-500 family (ID500)";
    if ([reply isEqualToString:@"ID501;"]) return @"Lab599 radio (ID501)";
    if ([reply isEqualToString:@"ID502;"]) return @"Lab599 radio (ID502)";
    if ([reply isEqualToString:@"ID505;"]) return @"Lab599 TX-500MP (ID505)";
    return nil;
}

@interface TXCATSummary : NSObject <NSCopying>
@property(nonatomic) NSUInteger checks;
@property(nonatomic) NSUInteger passed;
@property(nonatomic) NSUInteger failed;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL connectionFailed;
@property(nonatomic) TXCATCode lastCode;
@property(nonatomic) double responseMilliseconds;
@property(nonatomic, copy) NSString *lastReply;
@property(nonatomic, copy) NSString *message;
@end

// Transceiver Live State Snapshot
@interface TXRadioState : NSObject <NSCopying>
@property(nonatomic) uint64_t frequencyHz;
@property(nonatomic, copy) NSString *frequencyDisplay; // e.g. "14.074.000 MHz"
@property(nonatomic, copy) NSString *operatingMode;    // e.g. "USB", "LSB", "CW", "DIG", "FM", "AM"
@property(nonatomic) NSInteger modeCode;               // 1-7
@property(nonatomic) double rfPowerWatts;              // 1.0 - 10.0
@property(nonatomic) NSInteger filterNumber;           // 1, 2, 3, 4
@property(nonatomic) BOOL filterKnown;
@property(nonatomic) BOOL preampOn;
@property(nonatomic) BOOL preampKnown;
@property(nonatomic) BOOL attenuatorOn;
@property(nonatomic) BOOL attenuatorKnown;
@property(nonatomic) double voltage;                   // e.g. 13.8 V
@property(nonatomic) BOOL voltageKnown;
@property(nonatomic) NSInteger sMeterDots;             // 0-30
@property(nonatomic) BOOL sMeterKnown;
@property(nonatomic, copy) NSString *modelID;          // e.g. "ID019 (Lab599 TX-500)"
@property(nonatomic) BOOL isTransmitting;
@property(nonatomic, copy) NSString *rawIFReply;
@property(nonatomic, copy) NSString *rawFAReply;
@property(nonatomic, copy) NSString *rawMDReply;
@property(nonatomic, copy) NSString *rawPCReply;
@end

// Sends only ID; and accepts ID019, ID500, ID501, ID502 and ID505.
// update receives independent snapshots, safe to hand to the main queue.
FOUNDATION_EXPORT TXCATSummary *TXRunCATTest(NSString *path, TXCATOptions options,
    Lab599Cancellation *token, void (^update)(TXCATSummary *), void (^log)(NSString *));

// Interactive Command & Control API
FOUNDATION_EXPORT NSString *TXExecuteCATCommand(NSString *path, NSString *command,
    NSTimeInterval timeout, double *roundtripMs, NSError **error);

FOUNDATION_EXPORT TXRadioState *TXReadRadioState(NSString *path,
    NSTimeInterval timeout, NSError **error);

FOUNDATION_EXPORT BOOL TXSetRadioFrequency(NSString *path, uint64_t freqHz, NSError **error);
FOUNDATION_EXPORT BOOL TXSetRadioMode(NSString *path, NSInteger modeCode, NSError **error);
FOUNDATION_EXPORT BOOL TXSetRadioPower(NSString *path, double watts, NSError **error);
FOUNDATION_EXPORT BOOL TXSetRadioPreamp(NSString *path, BOOL on, NSError **error);
FOUNDATION_EXPORT BOOL TXSetRadioAttenuator(NSString *path, BOOL on, NSError **error);
FOUNDATION_EXPORT BOOL TXSetRadioFilter(NSString *path, NSInteger filterNumber, NSError **error);

// Automation accepts only a conservative set of read queries and non-PTT
// setters. Each setter is read back before the next command executes.
FOUNDATION_EXPORT NSArray<NSString *> *TXValidatedCATMacro(NSString *source, NSError **error);
FOUNDATION_EXPORT BOOL TXRunCATMacro(NSString *path, NSArray<NSString *> *commands,
    Lab599Cancellation *token, void (^progress)(NSUInteger index, NSString *command, NSString *reply), NSError **error);
