#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface TX500DXSpot : NSObject
@property(nonatomic,copy) NSString *identifier,*callsign,*spotter,*comment,*modeHint,*band,*country;
@property(nonatomic,copy) NSString *countryFlag;
@property(nonatomic) uint64_t frequencyHz;
@property(nonatomic,strong) NSDate *reportedAt,*receivedAt;
+ (nullable instancetype)parseLine:(NSString *)line receivedAt:(NSDate *)date;
- (BOOL)isStaleAt:(NSDate *)now;
@end
// Incremental bounded Telnet framing; no socket or radio side effects.
@interface TX500DXStream : NSObject
@property(nonatomic,copy,nullable) void (^lineHandler)(NSString *line);
@property(nonatomic,copy,nullable) void (^promptHandler)(NSString *prompt);
@property(nonatomic,copy,nullable) void (^replyHandler)(NSData *reply);
- (void)consume:(NSData *)data;
@end
@interface TX500DXAlertPolicy : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic,copy) NSString *calls,*countries;
- (BOOL)matches:(TX500DXSpot *)spot;
- (BOOL)shouldNotify:(TX500DXSpot *)spot now:(NSDate *)now;
@end
@interface TX500DXCluster : NSObject
@property(nonatomic,readonly,copy) NSArray<TX500DXSpot *> *spots;
@property(nonatomic,readonly,copy) NSString *status;
@property(nonatomic,readonly) BOOL running;
@property(nonatomic,copy,nullable) void (^changed)(void);
@property(nonatomic,copy,nullable) void (^receivedSpot)(TX500DXSpot *spot);
+ (BOOL)validHost:(NSString *)host port:(NSInteger)port callsign:(NSString *)call;
+ (NSTimeInterval)retryDelayForAttempt:(NSUInteger)attempt;
+ (NSArray<NSDictionary<NSString *,NSString *> *> *)recommendedNodes;
- (BOOL)connectHost:(NSString *)host port:(NSInteger)port callsign:(NSString *)call;
- (void)disconnect;
- (void)clear;
// Fixture ingestion shares parsing/deduplication with real traffic; never connects.
- (void)ingestLine:(NSString *)line receivedAt:(NSDate *)date;
@end
NS_ASSUME_NONNULL_END
