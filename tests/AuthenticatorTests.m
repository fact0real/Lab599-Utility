#import <Cocoa/Cocoa.h>
#import "TX500WebAuthenticatorController.h"
#import "TX500CloudSettingsController.h"

@interface TX500WebAuthenticatorController (Testing)
- (void)loadLoginPage;
- (void)readSessionCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion;
- (void)doneClicked;
- (void)cancelClicked;
- (void)webView:(nullable WKWebView *)webView didFinish:(nullable WKNavigation *)navigation;
@end
@interface TX500CloudSettingsController (Testing)
- (void)presentAuthenticatorForService:(TX500AuthService)service;
- (TX500WebAuthenticatorController *)newAuthenticatorForService:(TX500AuthService)service;
@end
@interface FakeAuthenticator : TX500WebAuthenticatorController
@property(copy) void (^pendingCookies)(NSArray<NSHTTPCookie *> *);
@property NSUInteger reads;
@end
@implementation FakeAuthenticator
- (void)loadLoginPage {} // Never contact QRZ or Club Log.
- (void)readSessionCookies:(void (^)(NSArray<NSHTTPCookie *> *))completion {
    self.reads++; self.pendingCookies=completion;
}
@end
@interface TestSettings : TX500CloudSettingsController
@end
@implementation TestSettings
- (TX500WebAuthenticatorController *)newAuthenticatorForService:(TX500AuthService)service {
    return [FakeAuthenticator authenticatorForService:service];
}
@end
static NSUInteger checks;
static void Check(BOOL ok, NSString *message) {
    checks++; if(!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
static void Pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    do { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; } while(end.timeIntervalSinceNow>0);
}
static NSHTTPCookie *Cookie(NSString *domain, BOOL expired) {
    return [NSHTTPCookie cookieWithProperties:@{NSHTTPCookieDomain:domain,NSHTTPCookiePath:@"/",NSHTTPCookieName:@"session",NSHTTPCookieValue:@"synthetic-test-only",NSHTTPCookieExpires:[NSDate dateWithTimeIntervalSinceNow:expired?-60:3600]}];
}
static void Reset(void) {
    for(NSString *key in @[@"TX500_QRZ_2FASessionCookies",@"TX500_QRZ_2FA_Active",@"TX500_ClubLog_2FASessionCookies",@"TX500_ClubLog_2FA_Active"]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}
int main(void) { @autoreleasepool {
    Check(getenv("CFFIXED_USER_HOME")!=NULL,@"Test preferences must be isolated");
    setenv("TX500_TEST_MODE","1",1);
    [NSApplication sharedApplication]; Reset();
    TestSettings *settings=[TestSettings new];
    NSWindow *parent=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,700) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    parent.releasedWhenClosed=NO; parent.contentView=settings.settingsView;
    [parent makeKeyAndOrderFront:nil];
    __block NSUInteger notifications=0; settings.onSettingsChanged=^{notifications++;};
    __weak FakeAuthenticator *weakAuth;
    @autoreleasepool {
    @autoreleasepool {
        [settings presentAuthenticatorForService:TX500AuthServiceQRZ];
        weakAuth=[settings valueForKey:@"activeAuthenticator"];
    }
    Pump(0.1);
    Check(weakAuth!=nil,@"Settings retains authenticator after login action returns");
    FakeAuthenticator *auth=weakAuth;
    Check(auth.window.sheetParent==parent,@"Embedded settings attaches login to its actual parent window");
    [settings presentAuthenticatorForService:TX500AuthServiceQRZ];
    Check([settings valueForKey:@"activeAuthenticator"]==auth,@"Repeated login does not create another controller");
    [auth webView:nil didFinish:nil];
    Check(auth.reads==0 && auth.window.visible,@"Page completion cannot treat anonymous cookies as successful 2FA");
    NSButton *done=[auth valueForKey:@"doneButton"];
    [done performClick:nil]; [auth doneClicked];
    Check(auth.reads==1 && !done.enabled,@"Done still has a live target and duplicate saves are blocked");
    auth.pendingCookies(@[]); Pump(0.1);
    Check(auth.window.visible && done.enabled && notifications==0,@"No cookies keeps window open with retry available");
    [done performClick:nil];
    auth.pendingCookies(@[Cookie(@"qrz.com.evil.example",NO),Cookie(@"notqrz.com",NO),Cookie(@".qrz.com",YES)]); Pump(0.1);
    Check(![TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ],@"Expired and lookalike-domain cookies are excluded");
    [done performClick:nil]; auth.pendingCookies(@[Cookie(@".qrz.com",NO)]); Pump(0.2);
    Check(!auth.window.visible && parent.attachedSheet==nil,@"Successful Done dismisses sheet and window");
    Check([settings valueForKey:@"activeAuthenticator"]==nil,@"Owner releases completed authenticator");
    Check([TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ],@"Done saves session before reporting completion");
    [auth cancelClicked]; auth.pendingCookies(@[Cookie(@".qrz.com",NO)]); Pump(0.1);
    Check(notifications==1,@"Late callbacks and Cancel cannot complete twice");
    auth=nil; Pump(0.1);
    }
    Pump(0.1);
    Check(weakAuth==nil,@"Completed controller is not leaked");
    Reset();
    FakeAuthenticator *auth;
    [settings presentAuthenticatorForService:TX500AuthServiceQRZ]; auth=[settings valueForKey:@"activeAuthenticator"];
    [auth doneClicked]; [auth cancelClicked]; auth.pendingCookies(@[Cookie(@"qrz.com",NO)]); Pump(0.2);
    Check(!auth.window.visible && notifications==2,@"Cancel dismisses an in-progress save once");
    Check(![TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ],@"Cancelled late cookie read cannot persist session");
    TestSettings *standaloneSettings=[TestSettings new];
    standaloneSettings.onSettingsChanged=^{notifications++;};
    [standaloneSettings presentAuthenticatorForService:TX500AuthServiceClubLog]; auth=[standaloneSettings valueForKey:@"activeAuthenticator"];
    [auth.window performClose:nil]; Pump(0.2);
    Check(!auth.window.visible && [standaloneSettings valueForKey:@"activeAuthenticator"]==nil && notifications==3,@"Red close button cancels and releases standalone controller");
    FakeAuthenticator *standalone=[FakeAuthenticator authenticatorForService:TX500AuthServiceClubLog];
    __block NSUInteger finished=0;
    [standalone presentModalOverWindow:nil completion:^(BOOL ok,NSString *message){(void)message; Check(ok,@"Standalone save succeeds"); finished++;}];
    [standalone doneClicked]; Pump(10.2);
    Check([[standalone valueForKey:@"doneButton"] isEnabled] && standalone.window.visible,@"Stalled save times out and allows retry");
    standalone.pendingCookies(@[Cookie(@"clublog.org",NO)]); Pump(0.1);
    Check(finished==0,@"Timed-out request cannot later save or dismiss");
    [standalone doneClicked]; standalone.pendingCookies(@[Cookie(@"clublog.org",NO)]); Pump(0.2);
    Check(finished==1 && !standalone.window.visible,@"Standalone Club Log save closes window");
    Check([TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceClubLog],@"Club Log session stored independently");
    Reset(); [parent close];
    printf("PASS: %lu authenticator lifecycle checks; synthetic cookies only, no service login.\n",(unsigned long)checks);
} return 0; }
