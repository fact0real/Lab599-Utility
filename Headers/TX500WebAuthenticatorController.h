//
//  TX500WebAuthenticatorController.h
//  Lab599 Utility
//
//  Native WebKit Authenticator & 2FA/MFA Session Manager
//  Supports QRZ.com and Club Log 2FA/MFA web login, OTP code entry,
//  and automatic session cookie capture.
//

#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500AuthService) {
    TX500AuthServiceQRZ = 0,
    TX500AuthServiceClubLog = 1
};

@interface TX500WebAuthenticatorController : NSWindowController <WKNavigationDelegate>

@property (nonatomic, assign, readonly) TX500AuthService service;
@property (nonatomic, copy, nullable) void (^completionHandler)(BOOL success, NSString *message);

+ (instancetype)authenticatorForService:(TX500AuthService)service;

- (void)presentModalOverWindow:(nullable NSWindow *)parentWindow
                    completion:(nullable void (^)(BOOL success, NSString *message))completion;

+ (BOOL)hasSavedSessionForService:(TX500AuthService)service;
+ (void)clearSessionForService:(TX500AuthService)service;
+ (nullable NSString *)cookieHeaderForService:(TX500AuthService)service;

@end

NS_ASSUME_NONNULL_END
