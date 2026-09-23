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
@property(nonatomic, readonly) NSUInteger queryCount;
@property(nonatomic, readonly) NSUInteger failureCount;
@property(nonatomic, readonly) double lastLatency;
@property(nonatomic, copy, nullable) id (^transportFactory)(NSString *path);
- (BOOL)selectOwner:(NSString *)owner port:(NSString *)path error:(NSError **)error;
- (nullable NSString *)query:(NSString *)command error:(NSError **)error;
- (BOOL)send:(NSString *)command owner:(NSString *)owner error:(NSError **)error;
- (BOOL)transmit:(BOOL)active owner:(NSString *)owner error:(NSError **)error;
- (nullable NSDictionary *)readState:(NSError **)error;
- (BOOL)tune:(uint64_t)hz mode:(NSInteger)mode owner:(NSString *)owner error:(NSError **)error;
- (BOOL)releaseOwnedTX:(NSError **)error;
- (BOOL)suspend:(NSError **)error;
- (id<TX500VoiceRadio>)voiceAdapter;
@end
NS_ASSUME_NONNULL_END
