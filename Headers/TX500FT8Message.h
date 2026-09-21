//
//  TX500FT8Message.h
//  Lab599 Utility
//
//  FT8 Message Parser, Maidenhead Grid Geolocation, DXCC Prefix Resolver & ADIF Generator
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500FT8MessageType) {
    TX500FT8MessageTypeUnknown = 0,
    TX500FT8MessageTypeCQ,
    TX500FT8MessageTypeReplyGrid,       // HisCall MyCall Grid
    TX500FT8MessageTypeReport,          // HisCall MyCall +02 / -12
    TX500FT8MessageTypeRogerReport,     // HisCall MyCall R+02 / R-12
    TX500FT8MessageTypeRRR,             // HisCall MyCall RRR
    TX500FT8MessageTypeRR73,            // HisCall MyCall RR73
    TX500FT8MessageType73,              // HisCall MyCall 73
    TX500FT8MessageTypeFreeText
};

@interface TX500FT8Message : NSObject <NSCopying>

// Raw & Decoded Telemetry
@property (nonatomic, copy) NSString *rawText;
@property (nonatomic, assign) float freqHz;
@property (nonatomic, assign) float snrDb;
@property (nonatomic, assign) float timeSec; // DT
@property (nonatomic, strong) NSDate *timestamp;
@property (nonatomic, assign) NSInteger slotParity; // 0=Even (:00,:30), 1=Odd (:15,:45)

// Structured Semantic Fields
@property (nonatomic, assign) TX500FT8MessageType messageType;
@property (nonatomic, copy, nullable) NSString *callerCall;  // Station sending/originating
@property (nonatomic, copy, nullable) NSString *targetCall;  // Destination (or "CQ")
@property (nonatomic, copy, nullable) NSString *grid;        // e.g. "KM35" or "FN31pr"
@property (nonatomic, copy, nullable) NSString *snrReport;   // e.g. "-12" or "+04"
@property (nonatomic, assign) BOOL isRoger;

// Contextual Flags (against MyStation)
@property (nonatomic, assign) BOOL isCQ;
@property (nonatomic, assign) BOOL isDirectedToMe;
@property (nonatomic, assign) BOOL isMyTransmission;

// Geolocation & DXCC Intelligence
@property (nonatomic, copy) NSString *countryName;
@property (nonatomic, copy) NSString *countryFlag;
@property (nonatomic, assign) double distanceKm;
@property (nonatomic, assign) double bearingDeg;

// Factory Constructors
+ (instancetype)messageWithRawText:(NSString *)rawText
                            freqHz:(float)freq
                             snrDb:(float)snr
                                dt:(float)dt
                          slotDate:(nullable NSDate *)slotDate
                        slotParity:(NSInteger)parity
                            myCall:(NSString *)myCall
                            myGrid:(NSString *)myGrid;

+ (instancetype)messageWithRawText:(NSString *)rawText
                            freqHz:(float)freq
                             snrDb:(float)snr
                                dt:(float)dt
                            myCall:(NSString *)myCall
                            myGrid:(NSString *)myGrid;

// Maidenhead Math & Utilities
+ (BOOL)parseMaidenhead:(NSString *)grid outLat:(double *)outLat outLon:(double *)outLon;
+ (double)distanceKmFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid;
+ (double)bearingDegFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid;

// DXCC & Country Resolver
+ (NSString *)countryNameForCallsign:(NSString *)call;
+ (NSString *)countryFlagForCallsign:(NSString *)call;

// Standard Message Generation for Transmit Slots
+ (NSString *)messageForPhase:(NSInteger)phase
                       myCall:(NSString *)myCall
                       myGrid:(NSString *)myGrid
                       dxCall:(NSString *)dxCall
                       dxGrid:(nullable NSString *)dxGrid
                     myReport:(nullable NSString *)myReport
                   rcvdReport:(nullable NSString *)rcvdReport;

// ADIF Record Formatter
+ (NSString *)adifRecordForCall:(NSString *)dxCall
                           band:(NSString *)band
                         freqHz:(uint64_t)freqHz
                        rstSent:(NSString *)rstSent
                        rstRcvd:(NSString *)rstRcvd
                           grid:(nullable NSString *)grid
                           date:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END
