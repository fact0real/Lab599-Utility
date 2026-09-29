#import <Foundation/Foundation.h>
#import <Security/Security.h>

// Keep cloud credentials in the user's login Keychain. Test binaries can be
// compiled with TX500_TEST_SECRET_STORE to use their isolated preferences.
static inline BOOL TX500SecretKeyIsAllowed(NSString *key) {
    static NSSet<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = [NSSet setWithArray:@[@"TX500_LoTW_Password", @"TX500_LoTW_CertificatePassword",
            @"TX500_QRZ_APIKey", @"TX500_QRZ_Password", @"TX500_ClubLog_Password",
            @"TX500_ClubLog_APIKey", @"TX500_EQSL_Password", @"TX500_HamQTH_Password",
            @"TX500_QRZ_2FASessionCookies", @"TX500_ClubLog_2FASessionCookies"]];
    });
    return [keys containsObject:key];
}

static inline NSDictionary *TX500SecretQuery(NSString *key) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: @"ir.factoreal.lab599-utility.cloud-secrets",
             (__bridge id)kSecAttrAccount: key,
             (__bridge id)kSecAttrSynchronizable: @NO};
}

static inline BOOL TX500StoreSecret(NSString *key, NSString *value) {
    if (!TX500SecretKeyIsAllowed(key)) return NO;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
#ifdef TX500_TEST_SECRET_STORE
    [defaults setObject:value forKey:key];
    return YES;
#else
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || value.length == 0) return NO;
    NSDictionary *query = TX500SecretQuery(key);
    NSMutableDictionary *insert = [query mutableCopy];
    insert[(__bridge id)kSecValueData] = data;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)insert, NULL);
    if (status == errSecDuplicateItem)
        status = SecItemUpdate((__bridge CFDictionaryRef)query,
            (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
    if (status != errSecSuccess) return NO;
    [defaults removeObjectForKey:key];
    [defaults synchronize];
    return YES;
#endif
}

static inline NSString *TX500SecretValue(NSString *key) {
    if (!TX500SecretKeyIsAllowed(key)) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
#ifdef TX500_TEST_SECRET_STORE
    return [defaults stringForKey:key];
#else
    NSMutableDictionary *query = [TX500SecretQuery(key) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess) {
        NSData *data = CFBridgingRelease(result);
        NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (value.length) {
            [defaults removeObjectForKey:key];
            [defaults synchronize];
        }
        return value;
    }
    if (status != errSecItemNotFound) return nil;
    // Migrate once. Never delete the old value until Keychain accepted it.
    NSString *legacy = [defaults stringForKey:key];
    if (legacy.length && TX500StoreSecret(key, legacy)) return legacy;
    return nil;
#endif
}

static inline BOOL TX500RemoveSecret(NSString *key) {
    if (!TX500SecretKeyIsAllowed(key)) return NO;
#ifndef TX500_TEST_SECRET_STORE
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)TX500SecretQuery(key));
    if (status != errSecSuccess && status != errSecItemNotFound) return NO;
#endif
    [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    [NSUserDefaults.standardUserDefaults synchronize];
    return YES;
}
