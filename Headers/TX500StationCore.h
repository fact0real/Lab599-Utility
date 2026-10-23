#import <Foundation/Foundation.h>
#import "TX500VoiceKeyer.h"
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const TXStationRadioChanged;
// All normal CAT users share this serialized transport. Maintenance tools use
// an exclusive handoff; their binary protocols never share a framed CAT stream.
@interface TX500StationCore : NSObject
@property(nonatomic, readonly, copy) NSString *owner;
@property(nonatomic, readonly, copy) NSDictionary *snapshot;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, readonly) BOOL ownsTX;
// Kept independently of polling status until the operator confirms physical receive.
@property(nonatomic, readonly, copy) NSString *transmitSafetyNotice;
- (void)acknowledgeTransmitSafetyNotice;
- (void)recordTransmitSafetyNotice:(NSString *)reason;
@property(nonatomic, readonly) NSUInteger queryCount;
@property(nonatomic, readonly) NSUInteger failureCount;
@property(nonatomic, readonly) double lastLatency;
@property(nonatomic, copy, nullable) id (^transportFactory)(NSString *path);
- (BOOL)selectOwner:(NSString *)owner port:(NSString *)path error:(NSError **)error;
- (nullable NSString *)query:(NSString *)command error:(NSError **)error;
// The deadline is the caller's (kept between 0.05 and 0.8 s); the old form keeps 0.8 s.
- (nullable NSString *)query:(NSString *)command timeout:(NSTimeInterval)timeout error:(NSError **)error;
- (BOOL)send:(NSString *)command owner:(NSString *)owner error:(NSError **)error;
- (BOOL)transmit:(BOOL)active owner:(NSString *)owner error:(NSError **)error;
- (nullable NSDictionary *)readState:(NSError **)error;
- (BOOL)tune:(uint64_t)hz mode:(NSInteger)mode owner:(NSString *)owner error:(NSError **)error;
- (BOOL)releaseOwnedTX:(NSError **)error;
- (BOOL)suspend:(NSError **)error;
- (void)forceCloseTransport;
- (id<TX500VoiceRadio>)voiceAdapter;
// One step for a screen change. releaseFirst: the owned TX is released and an unconfirmed RX
// answers NO with nothing changed. closePort (exclusive tools): then suspend, never a forced
// close. Neither: the owner changes only while no TX is owned (a screen that only looks keeps
// the keyed owner).
- (BOOL)handoffToOwner:(NSString *)owner port:(NSString *)path releaseFirst:(BOOL)releaseFirst closePort:(BOOL)closePort error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
