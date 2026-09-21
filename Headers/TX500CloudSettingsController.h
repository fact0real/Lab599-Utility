//
//  TX500CloudSettingsController.h
//  Lab599 Utility
//
//  Comprehensive Multi-Service Cloud Settings Window Controller
//  Provides dedicated tabs for LoTW (.p12 certificate, TQSL sync),
//  QRZ.com (API, XML, 2FA WebKit), Club Log (2FA WebKit), eQSL, and HamQTH.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const TX500CloudSettingsDidChangeNotification;

@interface TX500CloudSettingsController : NSWindowController

@property (nonatomic, copy, nullable) void (^onSettingsChanged)(void);
@property (nonatomic, strong, readonly) NSView *settingsView;

+ (instancetype)sharedController;
- (void)showSettingsWindowOver:(nullable NSWindow *)parentWindow;
- (void)selectTabWithService:(nullable NSString *)service;
- (void)loadSavedSettings;
- (void)saveAndApplyClicked;

@end

NS_ASSUME_NONNULL_END
