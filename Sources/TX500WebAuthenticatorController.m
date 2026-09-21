//
//  TX500WebAuthenticatorController.m
//  Lab599 Utility
//
//  Native WebKit Authenticator & 2FA/MFA Session Manager
//  Supports QRZ.com and Club Log 2FA/MFA web login, OTP code entry,
//  and automatic session cookie capture.
//

#import "TX500WebAuthenticatorController.h"

static NSString * const kQRZCookieKey = @"TX500_QRZ_2FASessionCookies";
static NSString * const kQRZActiveKey = @"TX500_QRZ_2FA_Active";
static NSString * const kClubLogCookieKey = @"TX500_ClubLog_2FASessionCookies";
static NSString * const kClubLogActiveKey = @"TX500_ClubLog_2FA_Active";

@interface TX500WebAuthenticatorController ()

@property (nonatomic, assign, readwrite) TX500AuthService service;
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, assign) BOOL isSessionCaptured;

@end

@implementation TX500WebAuthenticatorController

+ (instancetype)authenticatorForService:(TX500AuthService)service {
    TX500WebAuthenticatorController *ctrl = [[self alloc] init];
    ctrl.service = service;
    [ctrl setupWindowAndUI];
    return ctrl;
}

- (void)setupWindowAndUI {
    NSRect frame = NSMakeRect(0, 0, 740, 640);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    win.title = (self.service == TX500AuthServiceQRZ) ? @"QRZ.com Authenticator & 2FA" : @"Club Log Authenticator & 2FA";
    win.minSize = NSMakeSize(580, 500);
    [win center];

    self.window = win;
    NSView *content = win.contentView;

    // Header Bar
    NSBox *headerBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    headerBox.boxType = NSBoxCustom;
    headerBox.translatesAutoresizingMaskIntoConstraints = NO;
    headerBox.borderWidth = 0.0;
    headerBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
    [content addSubview:headerBox];

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(macOS 11.0, *)) {
        iconView.image = [NSImage imageWithSystemSymbolName:@"lock.shield.fill" accessibilityDescription:@"Security"];
    }
    iconView.contentTintColor = (self.service == TX500AuthServiceQRZ) ? [NSColor systemGreenColor] : [NSColor systemBlueColor];
    [headerBox addSubview:iconView];

    NSTextField *titleLabel = [NSTextField labelWithString:(self.service == TX500AuthServiceQRZ) ?
                               @"QRZ.com WebKit Authenticator (Supports 2FA/MFA)" :
                               @"Club Log WebKit Authenticator (Supports 2FA/MFA)"];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [headerBox addSubview:titleLabel];

    NSTextField *subLabel = [NSTextField labelWithString:@"Log in securely with your credentials & 2FA authenticator code. Session will be saved."];
    subLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    subLabel.textColor = [NSColor secondaryLabelColor];
    [headerBox addSubview:subLabel];

    NSButton *btnDone = [NSButton buttonWithTitle:@"Done / Save Session" target:self action:@selector(doneClicked)];
    btnDone.translatesAutoresizingMaskIntoConstraints = NO;
    btnDone.bezelStyle = NSBezelStyleRounded;
    btnDone.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [headerBox addSubview:btnDone];

    NSButton *btnCancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelClicked)];
    btnCancel.translatesAutoresizingMaskIntoConstraints = NO;
    btnCancel.bezelStyle = NSBezelStyleRounded;
    [headerBox addSubview:btnCancel];

    // WebKit View
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:config];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15";
    self.webView.navigationDelegate = self;
    [content addSubview:self.webView];

    // Bottom Status Bar
    NSBox *bottomBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    bottomBox.boxType = NSBoxCustom;
    bottomBox.translatesAutoresizingMaskIntoConstraints = NO;
    bottomBox.borderWidth = 0.0;
    bottomBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06];
    [content addSubview:bottomBox];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    [bottomBox addSubview:self.spinner];

    self.statusLabel = [NSTextField labelWithString:@"Connecting to authentication portal..."];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.statusLabel.textColor = [NSColor secondaryLabelColor];
    [bottomBox addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        // Header Box
        [headerBox.topAnchor constraintEqualToAnchor:content.topAnchor],
        [headerBox.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [headerBox.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [headerBox.heightAnchor constraintEqualToConstant:56.0],

        [iconView.leadingAnchor constraintEqualToAnchor:headerBox.leadingAnchor constant:14.0],
        [iconView.centerYAnchor constraintEqualToAnchor:headerBox.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:26.0],
        [iconView.heightAnchor constraintEqualToConstant:26.0],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10.0],
        [titleLabel.topAnchor constraintEqualToAnchor:headerBox.topAnchor constant:10.0],

        [subLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:2.0],

        [btnCancel.trailingAnchor constraintEqualToAnchor:headerBox.trailingAnchor constant:-12.0],
        [btnCancel.centerYAnchor constraintEqualToAnchor:headerBox.centerYAnchor],

        [btnDone.trailingAnchor constraintEqualToAnchor:btnCancel.leadingAnchor constant:-8.0],
        [btnDone.centerYAnchor constraintEqualToAnchor:headerBox.centerYAnchor],

        // Web View
        [self.webView.topAnchor constraintEqualToAnchor:headerBox.bottomAnchor],
        [self.webView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [self.webView.bottomAnchor constraintEqualToAnchor:bottomBox.topAnchor],

        // Bottom Box
        [bottomBox.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [bottomBox.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [bottomBox.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bottomBox.heightAnchor constraintEqualToConstant:32.0],

        [self.spinner.leadingAnchor constraintEqualToAnchor:bottomBox.leadingAnchor constant:12.0],
        [self.spinner.centerYAnchor constraintEqualToAnchor:bottomBox.centerYAnchor],
        [self.spinner.widthAnchor constraintEqualToConstant:16.0],
        [self.spinner.heightAnchor constraintEqualToConstant:16.0],

        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.spinner.trailingAnchor constant:8.0],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:bottomBox.trailingAnchor constant:-12.0],
        [self.statusLabel.centerYAnchor constraintEqualToAnchor:bottomBox.centerYAnchor]
    ]];

    [self loadLoginPage];
}

- (void)loadLoginPage {
    NSString *urlString = (self.service == TX500AuthServiceQRZ) ?
        @"https://www.qrz.com/login" :
        @"https://clublog.org/login.php";

    NSURL *url = [NSURL URLWithString:urlString];
    if (url) {
        [self.spinner startAnimation:nil];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Loading %@...", url.host];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [self.webView loadRequest:req];
    }
}

- (void)presentModalOverWindow:(nullable NSWindow *)parentWindow
                    completion:(nullable void (^)(BOOL success, NSString *message))completion {
    self.completionHandler = completion;
    self.isSessionCaptured = NO;
    if (parentWindow) {
        [parentWindow beginSheet:self.window completionHandler:^(NSModalResponse returnCode) {
            (void)returnCode;
        }];
    } else {
        [self.window makeKeyAndOrderFront:nil];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    (void)webView; (void)navigation;
    [self.spinner startAnimation:nil];
    self.statusLabel.stringValue = @"Loading login portal...";
}

- (void)webView:(WKWebView *)webView didFinish:(WKNavigation *)navigation {
    (void)navigation;
    [self.spinner stopAnimation:nil];
    self.statusLabel.stringValue = @"Page loaded. Enter credentials & 2FA code if prompted.";
    [self captureCookiesManual:NO];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    (void)webView; (void)navigation;
    [self.spinner stopAnimation:nil];
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Navigation error: %@", error.localizedDescription];
}

#pragma mark - Cookie Capture & Session Persistence

- (void)captureCookiesManual:(BOOL)isManual {
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    NSString *targetDomain = (self.service == TX500AuthServiceQRZ) ? @"qrz.com" : @"clublog.org";

    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableArray<NSString *> *pairs = [NSMutableArray array];
        BOOL hasLoginSession = NO;

        for (NSHTTPCookie *c in cookies) {
            if ([c.domain containsString:targetDomain]) {
                [pairs addObject:[NSString stringWithFormat:@"%@=%@", c.name, c.value]];
                NSString *nameLower = [c.name lowercaseString];
                if ([nameLower containsString:@"session"] ||
                    [nameLower containsString:@"qrz"] ||
                    [nameLower containsString:@"login"] ||
                    [nameLower containsString:@"auth"] ||
                    [nameLower containsString:@"remember"]) {
                    hasLoginSession = YES;
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (pairs.count > 0 && (hasLoginSession || isManual)) {
                NSString *cookieHeader = [pairs componentsJoinedByString:@"; "];
                NSString *cookieKey = (self.service == TX500AuthServiceQRZ) ? kQRZCookieKey : kClubLogCookieKey;
                NSString *activeKey = (self.service == TX500AuthServiceQRZ) ? kQRZActiveKey : kClubLogActiveKey;

                [[NSUserDefaults standardUserDefaults] setObject:cookieHeader forKey:cookieKey];
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:activeKey];
                [[NSUserDefaults standardUserDefaults] synchronize];

                self.isSessionCaptured = YES;
                self.statusLabel.stringValue = @"✅ 2FA Session verified & saved successfully!";

                if (self.completionHandler) {
                    self.completionHandler(YES, @"2FA Session verified and saved.");
                }

                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self closeWindow];
                });
            } else if (isManual) {
                self.statusLabel.stringValue = @"No login session cookie found yet. Please finish signing in first.";
            }
        });
    }];
}

- (void)doneClicked {
    [self captureCookiesManual:YES];
}

- (void)cancelClicked {
    if (self.completionHandler) {
        self.completionHandler(NO, @"Authentication cancelled by user.");
    }
    [self closeWindow];
}

- (void)closeWindow {
    if (self.window.sheetParent) {
        [self.window.sheetParent endSheet:self.window];
    }
    [self.window close];
}

#pragma mark - Class Helpers

+ (BOOL)hasSavedSessionForService:(TX500AuthService)service {
    NSString *cookieKey = (service == TX500AuthServiceQRZ) ? kQRZCookieKey : kClubLogCookieKey;
    NSString *cookies = [[NSUserDefaults standardUserDefaults] stringForKey:cookieKey];
    if (cookies.length == 0) return NO;

    NSString *activeKey = (service == TX500AuthServiceQRZ) ? kQRZActiveKey : kClubLogActiveKey;
    if ([[NSUserDefaults standardUserDefaults] objectForKey:activeKey]) {
        return [[NSUserDefaults standardUserDefaults] boolForKey:activeKey];
    }
    return YES;
}

+ (void)clearSessionForService:(TX500AuthService)service {
    NSString *activeKey = (service == TX500AuthServiceQRZ) ? kQRZActiveKey : kClubLogActiveKey;
    NSString *cookieKey = (service == TX500AuthServiceQRZ) ? kQRZCookieKey : kClubLogCookieKey;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:activeKey];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:cookieKey];
    if (service == TX500AuthServiceQRZ) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_QRZ_2FAActive"];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_ClubLog_2FAActive"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Clear cookies in default data store
    WKWebsiteDataStore *store = [WKWebsiteDataStore defaultDataStore];
    [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSString *targetDomain = (service == TX500AuthServiceQRZ) ? @"qrz.com" : @"clublog.org";
        for (NSHTTPCookie *c in cookies) {
            if ([c.domain containsString:targetDomain]) {
                [store.httpCookieStore deleteCookie:c completionHandler:nil];
            }
        }
    }];
}

+ (nullable NSString *)cookieHeaderForService:(TX500AuthService)service {
    NSString *cookieKey = (service == TX500AuthServiceQRZ) ? kQRZCookieKey : kClubLogCookieKey;
    return [[NSUserDefaults standardUserDefaults] stringForKey:cookieKey];
}

@end
