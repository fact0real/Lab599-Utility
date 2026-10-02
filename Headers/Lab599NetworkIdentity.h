#import <Foundation/Foundation.h>

// Identify our own requests to Lab599; never impersonate a web browser.
static inline NSString *Lab599HTTPUserAgent(void) {
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:NSString.class] || version.length == 0) version = @"dev";
    return [NSString stringWithFormat:@"Lab599-Utility/%@ (+https://github.com/fact0real/Lab599-Utility)", version];
}
