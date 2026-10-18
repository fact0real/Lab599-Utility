#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import "TX500TimeDiscipline.h"
#import "Lab599DocsController.h"

static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSInteger requests = 0;
@interface OfflineProtocol : NSURLProtocol @end
@implementation OfflineProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { (void)request; return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    @synchronized (OfflineProtocol.class) { requests++; }
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}
- (void)stopLoading {}
@end
static NSInteger RequestCount(void) { @synchronized (OfflineProtocol.class) { return requests; } }
static BOOL WaitFor(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!condition() && deadline.timeIntervalSinceNow > 0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return condition();
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *suite = [@"Lab599StartupTests-" stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
        Method prefs = class_getClassMethod(NSUserDefaults.class, @selector(standardUserDefaults));
        IMP realPrefs = method_setImplementation(prefs, imp_implementationWithBlock(^NSUserDefaults *{ return defaults; }));
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.protocolClasses = @[OfflineProtocol.class];
        Method configMethod = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
        IMP realConfig = method_setImplementation(configMethod, imp_implementationWithBlock(^NSURLSessionConfiguration *{ return config; }));
        Lab599DocsController *docs = [Lab599DocsController new];
        Check(RequestCount() == 0, @"Documentation construction uses only the bundled catalog");
        [docs fetchCatalogFromWeb];
        Check(WaitFor(^BOOL { return RequestCount() == 2; }), @"Explicit catalog fetch contacts both documented endpoints through offline stand-ins");
        method_setImplementation(configMethod, realConfig);

        TX500DisciplinedClock *clock = TX500DisciplinedClock.sharedClock;
        __block NSInteger ntpRequests = 0;
        Method query = class_getInstanceMethod(TX500DisciplinedClock.class, NSSelectorFromString(@"queryNTPServer:measurement:"));
        IMP realQuery = method_setImplementation(query, imp_implementationWithBlock(^BOOL(id object, NSString *server, void *measurement) {
            (void)object; (void)measurement;
            Check([@[@"time.cloudflare.com", @"time.apple.com", @"time.nist.gov"] containsObject:server], @"Only documented NTP servers are queried");
            @synchronized (clock) { ntpRequests++; }
            return NO;
        }));
        __block BOOL disabledAnswered = NO;
        [clock synchronizeNetworkNowWithCompletion:^(BOOL ok, NSString *detail) { disabledAnswered = !ok && [detail containsString:@"disabled"]; }];
        [clock startAutomaticNetworkSynchronization];
        Check(disabledAnswered && ntpRequests == 0, @"Default-off NTP blocks manual sampling and timer startup");
        [defaults setBool:YES forKey:@"TX500_NetworkTimeEnabled"];
        [clock startAutomaticNetworkSynchronization];
        Check(WaitFor(^BOOL { @synchronized (clock) { return ntpRequests == 3; } }), @"Enabled sampler uses three NTP stand-ins without HTTPS fallback");
        [defaults setBool:NO forKey:@"TX500_NetworkTimeEnabled"];
        [clock stopAutomaticNetworkSynchronization];
        [clock synchronizeNetworkNowWithCompletion:nil];
        Check(ntpRequests == 3, @"Disabled synchronization issues no further queries");
        method_setImplementation(query, realQuery);
        [defaults removePersistentDomainForName:suite];
        method_setImplementation(prefs, realPrefs);
        NSString *clockSource = [NSString stringWithContentsOfFile:@"Sources/TX500TimeDiscipline.m" encoding:NSUTF8StringEncoding error:NULL];
        Check(![clockSource containsString:@"https://"] && ![clockSource containsString:@"queryHTTPSTimeURL"], @"No HTTPS clock fallback remains");
        NSString *keyer = [NSString stringWithContentsOfFile:@"Sources/TX500CWKeyer.m" encoding:NSUTF8StringEncoding error:NULL];
        NSRange initStart = [keyer rangeOfString:@"- (instancetype)init"];
        NSRange dealloc = [keyer rangeOfString:@"- (void)dealloc"];
        Check(initStart.location != NSNotFound && dealloc.location > initStart.location &&
            ![[keyer substringWithRange:NSMakeRange(initStart.location, dealloc.location - initStart.location)] containsString:@"[self setupSidetoneAudio]"], @"Keyer initialization does not construct the sidetone audio engine");
        printf("PASS: offline documentation demand, default-off NTP, explicit activation, disabling and deferred sidetone\n");
    }
    return 0;
}
