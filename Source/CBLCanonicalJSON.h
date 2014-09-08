//
//  CBLCanonicalJSON.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 8/15/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>

/** Generates a canonical JSON form of an object tree, suitable for signing.
    See algorithm at <http://wiki.apache.org/couchdb/SignedDocuments>. */
@interface CBLCanonicalJSON : NSObject
{
    @private
    id _input;
    NSString* _ignoreKeyPrefix;
    NSArray* _whitelistedKeys;
    NSMutableString* _output;
    NSError* _error;
}

- (instancetype) initWithObject: (id)object;

/** If non-nil, dictionary keys beginning with this prefix will be ignored. */
@property (nonatomic, copy) NSString* ignoreKeyPrefix;

/** Keys to include even if they begin with the ignorePrefix. */
@property (nonatomic, copy) NSArray* whitelistedKeys;

/** Canonical JSON string from the input object tree.
    This isn't directly useful for tasks like signing or generating digests; you probably want to use .canonicalData instead for that. */
@property (readonly) NSString* canonicalString;

/** Canonical form of UTF-8 encoded JSON data from the input object tree. */
@property (readonly) NSData* canonicalData;

@property (readonly) NSError* error;


/** Convenience method that instantiates a CBLCanonicalJSON object and uses it to encode the object. */
+ (NSData*) canonicalData: (id)rootObject error: (NSError**)error;

/** Convenience method that instantiates a CBLCanonicalJSON object and uses it to encode the object, returning a string. */
+ (NSString*) canonicalString: (id)rootObject error: (NSError**)error;


/** Returns a dictionary's keys in the same order in which they would be written out in canonical JSON. */
+ (NSArray*) orderedKeys: (NSDictionary*)dict;

@end
