//
//  CBLCookieStorage.m
//  CouchbaseLite
//
//  Created by Pasin Suriyentrakorn on 2/18/15.
//  Copyright (c) 2015 Couchbase, Inc. All rights reserved.
//

#import "CBLCookieStorage.h"
#import "CBLDatabase.h"
#import "CBLDatabase+Internal.h"
#import "CBLMisc.h"
#import "Logging.h"


NSString* const CBLCookieStorageCookiesChangedNotification = @"CookieStorageCookiesChanged";
NSString* const CBLCookieStorageAcceptPolicyChangedNotification = @"CookieStorageAcceptPolicyChanged";

#define kLocalDocKeyPrefix @"cbl_cookie_storage"
#define kLocalDocCookiesKey @"cookies"

@interface CBLCookieStorage ()
- (NSString*) localDocKey;
- (void) loadCookies;
- (BOOL) deleteCookie: (NSHTTPCookie*)aCookie outIndex: (NSUInteger*)outIndex;
- (BOOL) saveCookies: (NSError **)error;
- (void) pruneExpiredCookies;
- (BOOL) isExpiredCookie: (NSHTTPCookie*)cookie;
- (BOOL) isDomainMatchedBetweenCookie: (NSHTTPCookie*)cookie andUrl: (NSURL*)url;
- (BOOL) isPathMatchedBetweenCookie: (NSHTTPCookie*)cookie andUrl: (NSURL*)url;
- (void) notifyCookiesChanged;
@end


@implementation CBLCookieStorage
{
    NSMutableArray* _cookies;
    CBLDatabase* _db;
    NSString* _storageKey;
}


@synthesize cookieAcceptPolicy = _cookieAcceptPolicy;


- (instancetype) initWithDB: (CBLDatabase*)db storageKey: (NSString*)storageKey {
    self = [super init];
    if (self) {
        Assert(db != nil, @"database cannot be nil.");
        Assert(storageKey != nil, @"storageKey cannot be nil.");

        _db = db;
        _storageKey = storageKey;
        self.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;

        [self loadCookies];
    }
    return self;
}


- (void) setCookieAcceptPolicy: (NSHTTPCookieAcceptPolicy)cookieAcceptPolicy {
    @synchronized(self) {
        if (cookieAcceptPolicy == NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain)
            Warn(@"%@: Currently NSHTTPCookieAcceptPolicyOnlyFromMainDocumentDomain \
                 is not supported.", self);

        if (_cookieAcceptPolicy != cookieAcceptPolicy) {
            _cookieAcceptPolicy = cookieAcceptPolicy;
            [[NSNotificationCenter defaultCenter] postNotificationName: CBLCookieStorageAcceptPolicyChangedNotification
                                                                object: self
                                                              userInfo: nil];
        }
    }
}


- (NSHTTPCookieAcceptPolicy) cookieAcceptPolicy {
    @synchronized(self) {
        return _cookieAcceptPolicy;
    }
}


- (NSArray*)cookies {
    @synchronized(self) {
        NSMutableArray *cookies = [NSMutableArray array];
        [_cookies enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
            NSHTTPCookie* cookie = (NSHTTPCookie*)obj;
            if (![self isExpiredCookie: cookie]) {
                [cookies addObject: cookie];
            }
        }];
        return cookies;
    }
}


- (NSArray*) cookiesForURL: (NSURL*)url {
    @synchronized(self) {
        if (!url)
            return nil;

        NSMutableArray* cookies = [NSMutableArray array];
        [_cookies enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
            NSHTTPCookie* cookie = (NSHTTPCookie*)obj;

            // Check whether the cookie is expired:
            if ([self isExpiredCookie: cookie])
                return;

            // NOTE:
            // From https://developer.apple.com/library/ios/documentation/Cocoa/Reference/Foundation/Classes/NSHTTPCookie_Class/index.html :
            // NSHTTPCookiePort : An NSString object containing comma-separated integer values specifying
            // the ports for the cookie. Only valid for Version 1 cookies or later. The default value is
            // an empty string (""). This cookie attribute is optional.
            //
            // However, there are a few discrepancies based on a test result as of 02/23/2015:
            // 1. Setting NSHTTPCookiePort also has effect on cookies version 0.
            // 2. Setting multiple values with comma-separated doesn't work. Only the first value is
            //    accepted.
            // 3. Setting to an empty string ("") results to a port number 0.
            //
            // So we are maintaining the same behaviors as what we have seen in the test result.
            //
            // If the cookie has no port list this method returns nil and the cookie will be sent
            // to any port. Otherwise, the cookie is only sent to ports specified in the port list.
            if ([cookie.portList count] > 0 && ![cookie.portList containsObject: url.port])
                return;

            // If a cookie is secure, it will be sent to only the secure urls:
            NSString* urlScheme = [url.scheme lowercaseString];
            if (cookie.isSecure && ![urlScheme isEqualToString: @"https"])
                return;

            //
            // Matching Rules:
            //
            // Domain Matching Rules:
            // 1. Matched if cookie domain == URL Host (Case insensitively).
            // 2. Or if Cookie domain begins with '.' (global domain cookies), matched if the URL host
            //    has the same domain as the cookie domain after dot. A url, which is a submodule of
            //    the cookie domain is also counted.
            //
            // Path Matching Rules (After the domain and the host are matched):
            // 1. Matched if the cookie path is a '/' or '<EMPTY>' string regardless of the url path.
            // 2. Or matched if the cookie path is a prefix of the url path.
            //
            if ([self isDomainMatchedBetweenCookie: cookie andUrl: url] &&
                [self isPathMatchedBetweenCookie: cookie andUrl: url])
                [cookies addObject:cookie];
        }];
        
        return cookies;
    }
}


- (NSArray*) sortedCookiesUsingDescriptors: (NSArray*)sortOrder {
    return [self.cookies sortedArrayUsingDescriptors: sortOrder];
}


- (void) setCookie: (NSHTTPCookie*)cookie {
    @synchronized(self) {
        if (!cookie)
            return;

        if (self.cookieAcceptPolicy == NSHTTPCookieAcceptPolicyNever)
            return;

        NSUInteger idx;
        if ([self deleteCookie: cookie outIndex: &idx])
            [_cookies insertObject:cookie atIndex:idx];
        else
            [_cookies addObject: cookie];

        NSError* error;
        if (![self saveCookies: &error])
            Warn(@"%@: Cannot save the cookie %@ with an error : %@", self, cookie, error);
        
        [self notifyCookiesChanged];
    }
}


- (void) deleteCookie: (NSHTTPCookie*)aCookie {
    @synchronized(self) {
        if (!aCookie)
            return;

        // NOTE: There is discrepancy about path matching when observing NSHTTPCookieStore behaviors:
        // 1. When adding or deleting a cookie, Comparing the cookie paths is case-insensitive.
        // 2. When getting cookies for a url, Matching the cookie paths is case-sensitive.
        if (![self deleteCookie:aCookie outIndex: nil])
            return;

        NSError* error;
        if (![self saveCookies: &error]) {
            Warn(@"%@: Cannot save cookies with an error : %@", self, error);
        }
        
        [self notifyCookiesChanged];
    }
}


- (void) deleteCookiesNamed: (NSString*)name {
    @synchronized(self) {
        for (NSInteger i = [_cookies count] - 1; i >= 0; i--) {
            NSHTTPCookie* cookie = _cookies[i];
            if ([cookie.name isEqualToString: name]) {
                [_cookies removeObjectAtIndex: i];
            }
        }

        NSError* error;
        if (![self saveCookies: &error]) {
            Warn(@"%@: Cannot save cookies with an error : %@", self, error);
        }

        [self notifyCookiesChanged];
    }
}

- (void) deleteAllCookies {
    @synchronized(self) {
        if ([_cookies count] == 0)
            return;

        [_cookies removeAllObjects];

        NSError* error;
        if (![self saveCookies: &error]) {
            Warn(@"%@: Cannot save cookies with an error : %@", self, error);
        }
        
        [self notifyCookiesChanged];
    }
}


- (void) dealloc {
    _db = nil;
    _cookies = nil;
}


# pragma mark - Private

- (NSString*) localDocKey {
    return [NSString stringWithFormat: @"%@_%@", kLocalDocKeyPrefix, _storageKey];
}


- (BOOL) deleteCookie: (NSHTTPCookie*)aCookie outIndex: (NSUInteger*)outIndex {
    __block NSInteger foundIndex = -1;
    [_cookies enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
        NSHTTPCookie* cookie = (NSHTTPCookie*)obj;
        if ([aCookie.name caseInsensitiveCompare: cookie.name] == 0 &&
            [aCookie.domain caseInsensitiveCompare: cookie.domain] == 0 &&
            [aCookie.path caseInsensitiveCompare: cookie.path] == 0) {
            foundIndex = idx;
            *stop = YES;
        }
    }];

    if (foundIndex >= 0)
        [_cookies removeObjectAtIndex:foundIndex];

    if (outIndex)
        *outIndex = foundIndex;

    return (foundIndex >= 0);
}


- (void) loadCookies {
    _cookies = [NSMutableArray array];

    NSString* key = [self localDocKey];
    NSArray* allCookies = [_db getLocalCheckpointDocumentPropertyValueForKey: key];
    [allCookies enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
        NSDictionary *props = [self cookiePropertiesFromJSONDocument: obj];
        NSHTTPCookie* cookie = [NSHTTPCookie cookieWithProperties: props];
        if (cookie)
            [_cookies addObject: cookie];
    }];
}


- (BOOL) saveCookies: (NSError **)error {
    [self pruneExpiredCookies];

    NSMutableArray* cookies = [NSMutableArray array];
    [_cookies enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL* stop) {
        NSHTTPCookie* cookie = (NSHTTPCookie*)obj;
        if (!cookie.sessionOnly) {
            NSDictionary *props = [self JSONDocumentFromCookieProperties: cookie.properties];
            [cookies addObject: props];
        }
    }];

    NSString* key = [self localDocKey];

    NSLog(@"KEYYYYYY: %@", key);

    return [_db putLocalCheckpointDocumentWithKey: key value: cookies outError: error];
}


- (void) pruneExpiredCookies {
    for (NSInteger i = [_cookies count] - 1; i >= 0; i--) {
        NSHTTPCookie* cookie = _cookies[i];
        if ([self isExpiredCookie: cookie])
            [_cookies removeObjectAtIndex: i];
    }
}

- (BOOL) isExpiredCookie: (NSHTTPCookie*)cookie {
    NSDate* expDate = cookie.expiresDate;
    return (expDate && [expDate compare: [NSDate date]] != NSOrderedDescending);
}


- (BOOL) shouldSaveCookie: (NSHTTPCookie*)cookie {
    return !cookie.sessionOnly && ![self isExpiredCookie: cookie];
}


- (BOOL) isDomainMatchedBetweenCookie: (NSHTTPCookie*)cookie andUrl: (NSURL*)url {
    NSString* urlHost = [url.host lowercaseString];
    NSString* cookieDomain = [cookie.domain lowercaseString];

    BOOL domainMatched = NO;
    if ([cookieDomain hasPrefix: @"."]) { // global domain cookie.
        NSString* domainAfterDot = [cookieDomain substringFromIndex: 1];
        domainMatched = [urlHost hasSuffix: domainAfterDot];
    } else
        domainMatched = [urlHost isEqualToString: cookieDomain];

    return domainMatched;
}


- (BOOL) isPathMatchedBetweenCookie: (NSHTTPCookie*)cookie andUrl: (NSURL*)url {
    NSString* cookiePath = cookie.path;
    if (cookiePath.length == 0 || [cookiePath isEqualToString: @"/"])
        return YES;

    // Cannot use url.path as it doesn't preserve a tailing '/'
    // or percent escaped strings.
#ifdef GNUSTEP
    NSString* urlPath = [url pathWithEscapes];
#else
    #ifdef __OBJC_GC__
    NSString* urlPath = NSMakeCollectable(CFURLCopyPath((CFURLRef)url));
    #else
    NSString* urlPath = (__bridge_transfer NSString *)CFURLCopyPath((__bridge CFURLRef)url);
    #endif
#endif

    if (![urlPath hasPrefix: cookiePath])
        return NO;

    BOOL matched =
        (urlPath.length == cookiePath.length) ||
        [urlPath characterAtIndex: cookiePath.length -
            ([cookiePath hasSuffix: @"/"] ? 1 : 0)] == '/';
    return matched;
}


- (NSDictionary*) JSONDocumentFromCookieProperties: (NSDictionary*)props {
    if (props[NSHTTPCookieExpires]) {
        NSMutableDictionary* newProps = [NSMutableDictionary dictionaryWithDictionary: props];
        newProps[NSHTTPCookieExpires] = [CBLJSON JSONObjectWithDate: props[NSHTTPCookieExpires]];
        props = newProps;
    }
    return props;
}


- (NSDictionary*) cookiePropertiesFromJSONDocument: (NSDictionary*)props {
    if (props[NSHTTPCookieExpires]) {
        NSMutableDictionary* newProps = [NSMutableDictionary dictionaryWithDictionary: props];
        newProps[NSHTTPCookieExpires] = [CBLJSON dateWithJSONObject: props[NSHTTPCookieExpires]];
        props = newProps;
    }
    return props;
}


- (void) notifyCookiesChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName: CBLCookieStorageCookiesChangedNotification
                                                        object: self
                                                      userInfo: nil];
}

@end


@implementation CBLCookieStorage (NSURLRequestResponse)

- (void) addCookieHeaderForRequest: (NSMutableURLRequest*)request {
    request.HTTPShouldHandleCookies = NO;
    NSArray* cookies = [self cookiesForURL: request.URL];
    if ([cookies count] > 0) {
        NSDictionary* cookieHeaders = [NSHTTPCookie requestHeaderFieldsWithCookies: cookies];
        [cookieHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            [request setValue:value forHTTPHeaderField:key];
        }];
    }
}


- (void) setCookieForResponse: (NSHTTPURLResponse*)response {
    NSArray* cookies = [NSHTTPCookie cookiesWithResponseHeaderFields:
                        response.allHeaderFields forURL: response.URL];
    for (NSHTTPCookie* cookie in cookies)
        [self setCookie: cookie];
}

@end
