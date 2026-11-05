#import "TX500DiagnosticPrivacy.h"
int main(void) { @autoreleasepool {
 NSCAssert(![TX500PrivateDiagnostic(@"{\"Cookie\": \"UNSAFE\"}") containsString:@"UNSAFE"], @"JSON header survived");
 NSCAssert(![TX500PrivateDiagnostic(@"https://example.org/path?%70assword=UNSAFE#token=UNSAFE") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"Authorization: Bearer UNSAFE\nnext line") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"Set-Cookie: session=UNSAFE") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"https://user:UNSAFE@example.org/x") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"{\"token\":\"UNSAFE value\", \"password\": \"UNSAFE\"}") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"<session_id>UNSAFE</session_id>") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert(![TX500PrivateDiagnostic(@"api_key=UNSAFE&mode=FT8") containsString:@"UNSAFE"], @"Secret survived");
 NSCAssert([TX500PrivateDiagnostic(@"CAT: timeout") isEqual:@"CAT: timeout"], @"Lost diagnostic");
 NSLog(@"Diagnostic privacy regression passed"); } return 0; }
