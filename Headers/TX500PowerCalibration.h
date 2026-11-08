#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Offline measurements only. This module has no serial, network or process API.
@interface TX500PowerCalibration : NSObject
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *rows;
@property(nonatomic, readonly) NSUInteger skippedRows;
- (BOOL)importCSVData:(NSData *)data error:(NSError **)error;
- (BOOL)addMeasurement:(NSDictionary<NSString *, NSString *> *)row error:(NSError **)error;
- (NSArray<NSArray<NSDictionary *> *> *)groups;
+ (NSString *)groupTitle:(NSArray<NSDictionary *> *)rows;
+ (NSString *)reportForRows:(NSArray<NSDictionary *> *)rows meter:(NSString *)meter;
+ (nullable NSNumber *)estimatedWattsForDots:(double)dots rows:(NSArray<NSDictionary *> *)rows meter:(NSString *)meter;
- (NSData *)CSVData;
@end
NS_ASSUME_NONNULL_END
