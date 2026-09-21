//
//  TX500CallsignLookupService.h
//  Lab599 Utility
//
//  Callsign Intelligence & Station Photo Service
//  Supports asynchronous QRZ.com XML and HamQTH.com lookups with 24-hour caching
//  and station photo retrieval.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface TX500LookupResult : NSObject <NSCopying>

@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) NSString *firstName;
@property (nonatomic, copy, nullable) NSString *lastName;
@property (nonatomic, copy, nullable) NSString *qth;
@property (nonatomic, copy, nullable) NSString *state;
@property (nonatomic, copy, nullable) NSString *county;
@property (nonatomic, copy, nullable) NSString *country;
@property (nonatomic, copy, nullable) NSString *grid;
@property (nonatomic, copy, nullable) NSString *dxcc;
@property (nonatomic, copy, nullable) NSString *cqZone;
@property (nonatomic, copy, nullable) NSString *ituZone;
@property (nonatomic, copy, nullable) NSString *imageURL;
@property (nonatomic, copy, nullable) NSString *email;
@property (nonatomic, assign) BOOL isLoTW;
@property (nonatomic, assign) BOOL isEQSL;
@property (nonatomic, copy) NSString *source;

- (BOOL)hasData;
- (NSString *)displayLocation;

@end

@interface TX500CallsignLookupService : NSObject

+ (instancetype)sharedService;

// Primary Lookup API
- (void)lookupCallsign:(NSString *)rawCallsign
            completion:(void (^)(TX500LookupResult * _Nullable result, NSError * _Nullable error))completion;

// Station Avatar / Photo Fetching
- (void)fetchImageForURLString:(NSString *)urlString
                    completion:(void (^)(NSImage * _Nullable image))completion;

// Cache Management
- (void)clearCache;

// Connection Tests
- (void)testQRZCredentialsWithUsername:(NSString *)username
                              password:(NSString *)password
                            completion:(void (^)(BOOL success, NSString *message))completion;

- (void)testHamQTHCredentialsWithUsername:(NSString *)username
                                 password:(NSString *)password
                               completion:(void (^)(BOOL success, NSString *message))completion;

// XML Parsing Helpers for unit tests
+ (nullable NSString *)extractXMLTag:(NSString *)tag fromString:(NSString *)xml;
+ (TX500LookupResult *)parseQRZXML:(NSString *)xml callsign:(NSString *)callsign;
+ (TX500LookupResult *)parseHamQTHXML:(NSString *)xml callsign:(NSString *)callsign;

@end

NS_ASSUME_NONNULL_END
