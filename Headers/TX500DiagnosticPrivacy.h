#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

static inline NSString *TX500PrivateDiagnostic(NSString *text) {
    if (!text) return @"";
    if ([text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536) return @"[Diagnostic omitted: size limit]";
    static NSArray<NSRegularExpression *> *expressions;
    static NSArray<NSString *> *replacements;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        expressions = @[
            [NSRegularExpression regularExpressionWithPattern:@"(?im)[\"'](?:authorization|proxy-authorization|cookie|set-cookie)[\"']\\s*:\\s*[^\\r\\n]*" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(?im)\\b(?:authorization|proxy-authorization|cookie|set-cookie)\\s*:[^\\r\\n]*" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(?i)(https?://)[^\\s/]+@" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(?i)(https?://[^\\s?\\#]+)[?\\#][^\\s]*" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(?i)([\"']?\\b(?:password|passwd|pass|p|key|api[_-]?key|access[_-]?token|refresh[_-]?token|token|session(?:[_-]?(?:id|key))?|s)\\b[\"']?\\s*[:=]\\s*)(?:\"[^\"\\r\\n]*\"|'[^'\\r\\n]*'|[^\\s&;,<>]+)" options:0 error:nil],
            [NSRegularExpression regularExpressionWithPattern:@"(?is)(<(?:password|pass|key|session_id|session|token|api_key)>).*?(</[^>]+>)" options:0 error:nil]
        ];
        replacements = @[@"[private header removed]", @"[private header removed]", @"$1[redacted]@", @"$1?[redacted]", @"$1[redacted]", @"$1[redacted]$2"];
    });
    NSString *result = text;
    for (NSUInteger index = 0; index < expressions.count; index++) {
        result = [expressions[index] stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:replacements[index]];
    }
    return [[result componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
}
