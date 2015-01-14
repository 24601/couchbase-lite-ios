//
//  CBLView+Internal.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/8/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CBLDatabase+Internal.h"
#import "CBLView.h"
#import "CBLQuery.h"
@class CBForestMapReduceIndex;


#define kViewIndexPathExtension @"viewindex"


extern NSString* const kCBLViewChangeNotification;

typedef enum {
    kCBLViewCollationUnicode,
    kCBLViewCollationRaw,
    kCBLViewCollationASCII
} CBLViewCollation;


/** Returns YES if the data is meant as a placeholder for the doc's entire data (a "*") */
BOOL CBLValueIsEntireDoc(NSData* valueData);
id CBLParseQueryValue(NSData* collatable);

BOOL CBLRowPassesFilter(CBLDatabase* db, CBLQueryRow* row, const CBLQueryOptions* options);


@interface CBLView ()
{
    @private
    CBLDatabase* __weak _weakDB;
    NSString* _name;
    uint8_t _collation;
}

- (instancetype) initWithDatabase: (CBLDatabase*)db name: (NSString*)name create: (BOOL)create;

- (void) databaseClosing;

+ (NSString*) fileNameToViewName: (NSString*)fileName;

@property (readonly) NSUInteger totalRows;

@property (readonly) MapReduceIndex* index;

@property (readonly) NSString* mapVersion;

@property (readonly) SequenceNumber lastSequenceChangedAt;

#if DEBUG  // for unit tests only
@property (readonly) NSString* indexFilePath;
- (void) setCollation: (CBLViewCollation)collation;
- (void) forgetMapBlock;
#endif

@end


@interface CBLView (Internal)

@property (readonly) NSArray* viewsInGroup;

/** Compiles a view (using the registered CBLViewCompiler) from the properties found in a CouchDB-style design document. */
- (BOOL) compileFromProperties: (NSDictionary*)viewProps
                      language: (NSString*)language;

/** Updates the view's index (incrementally) if necessary.
    If the index is updated, the other views in the viewGroup will be updated as a bonus.
    @return  200 if updated, 304 if already up-to-date, else an error code */
- (CBLStatus) updateIndex;

/** Updates the view's index (incrementally) if necessary. No other groups will be updated.
    @return  200 if updated, 304 if already up-to-date, else an error code */
- (CBLStatus) updateIndexAlone;

- (CBLStatus) updateIndexes: (NSArray*)views;

@end


@interface CBLView (Querying)

/** Queries the view. Does NOT first update the index.
    @param options  The options to use.
    @return  An array of CBLQueryRow. */
- (CBLQueryIteratorBlock) _queryWithOptions: (CBLQueryOptions*)options
                                     status: (CBLStatus*)outStatus;
- (NSData*) fullTextForDocument: (NSString*)docID
                       sequence: (SequenceNumber)sequence
                     fullTextID: (unsigned)fullTextID;
#if DEBUG
- (NSArray*) dump;
#endif

@end
