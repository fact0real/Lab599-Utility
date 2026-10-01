#import "Lab599HelpController.h"
#import <WebKit/WebKit.h>

@interface Lab599HelpController () <WKNavigationDelegate>
@property(nonatomic, strong, readwrite) NSView *view;
@property(nonatomic, strong) WKWebView *webView;
@property(nonatomic, strong) NSURL *helpURL;
@property(nonatomic) BOOL loaded;
@property(nonatomic, strong) NSLayoutConstraint *viewportHeightConstraint;
@end

@implementation Lab599HelpController

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    self.webView = [[WKWebView alloc] initWithFrame:NSZeroRect configuration:configuration];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    self.webView.navigationDelegate = self;
    self.webView.allowsBackForwardNavigationGestures = NO;
    self.view = self.webView;
    self.viewportHeightConstraint = [self.view.heightAnchor constraintEqualToConstant:620];
    self.viewportHeightConstraint.active = YES;

    self.helpURL = [[NSBundle mainBundle] URLForResource:@"index" withExtension:@"html" subdirectory:@"Help"];
    if (!self.helpURL) {
        NSString *developmentPath = @"Resources/Help/index.html";
        if ([[NSFileManager defaultManager] fileExistsAtPath:developmentPath]) {
            self.helpURL = [NSURL fileURLWithPath:[developmentPath stringByStandardizingPath]];
        }
    }
    return self;
}

- (void)loadHelpIfNeeded {
    if (self.loaded) return;
    self.loaded = YES;
    if (self.helpURL) {
        [self.webView loadFileURL:self.helpURL allowingReadAccessToURL:self.helpURL.URLByDeletingLastPathComponent];
    } else {
        [self.webView loadHTMLString:@"<html><body><h1>Help is unavailable</h1><p>The bundled guide could not be found. Reinstall the complete app.</p></body></html>" baseURL:nil];
    }
}

- (void)setViewportHeight:(CGFloat)height {
    self.viewportHeightConstraint.constant = MAX(420.0, height);
}

- (void)showTopic:(NSString *)topic {
    if (!self.helpURL || !topic.length) return;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"];
    if ([topic rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) return;
    NSURLComponents *components = [NSURLComponents componentsWithURL:self.helpURL resolvingAgainstBaseURL:NO];
    components.fragment = topic;
    [self.webView loadFileURL:components.URL allowingReadAccessToURL:self.helpURL.URLByDeletingLastPathComponent];
    self.loaded = YES;
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
 decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    (void)webView;
    NSURL *url = action.request.URL;
    if ([url.scheme isEqualToString:@"file"] &&
        [url.URLByStandardizingPath.path isEqualToString:self.helpURL.URLByStandardizingPath.path]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if ([url.scheme isEqualToString:@"https"] && action.navigationType == WKNavigationTypeLinkActivated) {
        [NSWorkspace.sharedWorkspace openURL:url];
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

@end
