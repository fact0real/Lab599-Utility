// SPDX-License-Identifier: GPL-3.0-or-later
// Every option of the SSTV screen's selectors, with a short "Good for / Not good for" note, the
// default too, so that nobody has to search or try blind.
#import <Foundation/Foundation.h>
#import "TX500SSTVEngine.h"

NS_ASSUME_NONNULL_BEGIN

/// What an input is: the radio's (from the Station screen), another interface, the Mac's own, or a
/// virtual one (another program's audio).
typedef NS_ENUM(NSInteger, TX500SSTVInputKind) {
    TX500SSTVInputRadio = 0, TX500SSTVInputOther, TX500SSTVInputBuiltIn, TX500SSTVInputVirtual
};

@interface TX500SSTVOptionNotes : NSObject
/// The titles of the mode selector, in TX500SSTVModeChoice order.
+ (NSArray<NSString *> *)modeTitles;
+ (NSString *)noteForMode:(TX500SSTVModeChoice)mode;
+ (NSArray<NSString *> *)colourScaleTitles;
+ (NSString *)noteForColourScale:(TX500SSTVColourScale)scale;
+ (NSArray<NSString *> *)scottieLayoutTitles;
+ (NSString *)noteForScottieLayout:(TX500SSTVScottieLayout)layout;
+ (NSString *)noteForInputKind:(TX500SSTVInputKind)kind;
/// The log form's switch «Also upload to Logbook»: ticked, the QSO is uploaded now; unticked (the
/// default), it stays pending in the Logbook until Sync All or Sync Selected there.
+ (NSString *)noteForUploadNow:(BOOL)ticked;
/// Record QSO or Discard QSO: what each is for. No rule: the operator's call.
+ (NSString *)noteForRecordOrDiscard;
/// The disk for the recordings: a share of the disk (1 % by default); 0 = Off.
+ (NSArray<NSNumber *> *)diskShares;
+ (NSArray<NSString *> *)diskTitles;
+ (NSString *)noteForDiskShareAtIndex:(NSInteger)index;
+ (NSInteger)defaultDiskIndex;
/// The fax tab's selectors ("deviation", "lpm", "ioc", "width", "lineStart"): each option
/// as @[title, note], the default first.
+ (NSArray<NSArray<NSString *> *> *)faxOptionsFor:(NSString *)selector;
@end

NS_ASSUME_NONNULL_END
