//
//  CBLDatabase+Internal.mm
//  CouchbaseLite
//
//  Created by Jens Alfke on 6/19/10.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import <CBForest/CBForest.hh>

extern "C" {
#import "CBLDatabase+Internal.h"
#import "CBLDatabase+Attachments.h"
#import "CBLInternal.h"
#import "CBLModel_Internal.h"
#import "CBL_Revision.h"
#import "CBLDatabaseChange.h"
#import "CBL_BlobStore.h"
#import "CBL_Puller.h"
#import "CBL_Pusher.h"
#import "CBL_Shared.h"
#import "CBLMisc.h"
#import "CBLDatabase.h"
#import "CouchbaseLitePrivate.h"

#import "MYBlockUtils.h"
#import "ExceptionUtils.h"
}


using namespace forestdb;


NSString* const CBL_DatabaseChangesNotification = @"CBLDatabaseChanges";
NSString* const CBL_DatabaseWillCloseNotification = @"CBL_DatabaseWillClose";
NSString* const CBL_DatabaseWillBeDeletedNotification = @"CBL_DatabaseWillBeDeleted";

NSString* const CBL_PrivateRunloopMode = @"CouchbaseLitePrivate";
NSArray* CBL_RunloopModes;

static BOOL sAutoCompact = YES;


@implementation CBLDatabase (Internal)

#define kLocalCheckpointDocId @"CBL_LocalCheckpoint"

static void FDBLogCallback(forestdb::logLevel level, const char *message) {
    switch (level) {
        case forestdb::kDebug:
            LogTo(CBLDatabaseVerbose, @"ForestDB: %s", message);
            break;
        case forestdb::kInfo:
            LogTo(CBLDatabase, @"ForestDB: %s", message);
            break;
        case forestdb::kWarning:
            Warn(@"%s", message);
        case forestdb::kError:
            Warn(@"ForestDB error: %s", message);
        default:
            break;
    }
}


+ (void) initialize {
    if (self == [CBLDatabase class]) {
        CBL_RunloopModes = @[NSRunLoopCommonModes, CBL_PrivateRunloopMode];

        [self setAutoCompact: YES];

        forestdb::LogCallback = FDBLogCallback;
        if (WillLogTo(CBLDatabaseVerbose))
            forestdb::LogLevel = kDebug;
        else if (WillLogTo(CBLDatabase))
            forestdb::LogLevel = kInfo;
    }
}


- (id<CBL_Storage>) storage {
    return _storage;
}

- (CBL_BlobStore*) attachmentStore {
    return _attachments;
}

- (NSDate*) startTime {
    return _startTime;
}


- (CBL_Shared*)shared {
#if DEBUG
    if (_manager)
        return _manager.shared;
    // For unit testing purposes we create databases without managers (see createEmptyDBAtPath(),
    // below.) Allow the .shared property to work in this state by creating a per-db instance:
    if (!_debug_shared)
        _debug_shared = [[CBL_Shared alloc] init];
    return _debug_shared;
#else
    return _manager.shared;
#endif
}


+ (BOOL) deleteDatabaseFilesAtPath: (NSString*)dbDir error: (NSError**)outError {
    return CBLRemoveFileIfExists(dbDir, outError);
}


#if DEBUG
+ (instancetype) createEmptyDBAtPath: (NSString*)dir {
    [self setAutoCompact: NO]; // unit tests don't want autocompact
    if (![self deleteDatabaseFilesAtPath: dir error: NULL])
        return nil;
    CBLDatabase *db = [[self alloc] initWithDir: dir name: nil manager: nil readOnly: NO];
    if (![db open: nil])
        return nil;
    AssertEq(db.lastSequenceNumber, 0); // Sanity check that this is not a pre-existing db
    return db;
}
#endif


- (instancetype) _initWithDir: (NSString*)dirPath
                         name: (NSString*)name
                      manager: (CBLManager*)manager
                     readOnly: (BOOL)readOnly
{
    if (self = [super init]) {
        Assert([dirPath hasPrefix: @"/"], @"Path must be absolute");
        _dir = [dirPath copy];
        _manager = manager;
        _name = name ?: [dirPath.lastPathComponent.stringByDeletingPathExtension copy];
        _readOnly = readOnly;

        _dispatchQueue = manager.dispatchQueue;
        if (!_dispatchQueue)
            _thread = [NSThread currentThread];
        _startTime = [NSDate date];
    }
    return self;
}

- (NSString*) description {
    return $sprintf(@"%@[<%p>%@]", [self class], self, self.name);
}

- (BOOL) exists {
    return [[NSFileManager defaultManager] fileExistsAtPath: _dir];
}


+ (void) setAutoCompact:(BOOL)autoCompact {
    sAutoCompact = autoCompact;
}


- (BOOL) open: (NSError**)outError {
    if (_isOpen)
        return YES;
    LogTo(CBLDatabase, @"Opening %@", self);

    // Create the database directory:
    if (![[NSFileManager defaultManager] createDirectoryAtPath: _dir
                                   withIntermediateDirectories: YES
                                                    attributes: nil
                                                         error: outError])
        return NO;

    // Open the ForestDB database:
    _storage = [[CBL_ForestDBStorage alloc] init];
    if (![_storage openInDirectory: _dir readOnly: _readOnly error: outError])
        return NO;
    _storage.autoCompact = sAutoCompact;

    // First-time setup:
    if (!self.privateUUID) {
        [_storage setInfo: CBLCreateUUID() forKey: @"privateUUID"];
        [_storage setInfo: CBLCreateUUID() forKey: @"publicUUID"];
    }

    // Open attachment store:
    NSString* attachmentsPath = self.attachmentStorePath;
    _attachments = [[CBL_BlobStore alloc] initWithPath: attachmentsPath error: outError];
    if (!_attachments) {
        Warn(@"%@: Couldn't open attachment store at %@", self, attachmentsPath);
        [_storage close];
        _storage = nil;
        return NO;
    }

    _isOpen = YES;

    // Listen for _any_ CBLDatabase changing, so I can detect changes made to my database
    // file by other instances (running on other threads presumably.)
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(dbChanged:)
                                                 name: CBL_DatabaseChangesNotification
                                               object: nil];
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(dbChanged:)
                                                 name: CBL_DatabaseWillBeDeletedNotification
                                               object: nil];
    return YES;
}

- (void) _close {
    if (_isOpen) {
        LogTo(CBLDatabase, @"Closing <%p> %@", self, _dir);
        // Don't want any models trying to save themselves back to the db. (Generally there shouldn't
        // be any, because the public -close: method saves changes first.)
        for (CBLModel* model in _unsavedModelsMutable.copy)
            model.needsSave = false;
        _unsavedModelsMutable = nil;
        
        [[NSNotificationCenter defaultCenter] postNotificationName: CBL_DatabaseWillCloseNotification
                                                            object: self];
        [[NSNotificationCenter defaultCenter] removeObserver: self
                                                        name: CBL_DatabaseChangesNotification
                                                      object: nil];
        [[NSNotificationCenter defaultCenter] removeObserver: self
                                                        name: CBL_DatabaseWillBeDeletedNotification
                                                      object: nil];
        for (CBLView* view in _views.allValues)
            [view databaseClosing];
        
        _views = nil;
        for (CBL_Replicator* repl in _activeReplicators.copy)
            [repl databaseClosing];
        
        _activeReplicators = nil;

        [_storage close];
        _storage = nil;

        _isOpen = NO;

        [[NSNotificationCenter defaultCenter] removeObserver: self];
        [self _clearDocumentCache];
        _modelFactory = nil;
    }
    [_manager _forgetDatabase: self];
}


- (NSUInteger) _documentCount {
    return _storage.documentCount;
}


- (SequenceNumber) _lastSequence {
    return _storage.lastSequence;
}


- (UInt64) totalDataSize {
    NSDirectoryEnumerator* e = [[NSFileManager defaultManager] enumeratorAtPath: _dir];
    UInt64 size = 0;
    while ([e nextObject])
        size += e.fileAttributes.fileSize;
    return size;
}


- (NSString*) privateUUID {
    return [_storage infoForKey: @"privateUUID"];
}

- (NSString*) publicUUID {
    return [_storage infoForKey: @"publicUUID"];
}


- (BOOL) _compact: (NSError**)outError {
    return [_storage compact: outError];
}


#pragma mark - TRANSACTIONS & NOTIFICATIONS:


- (CBLStatus) _inTransaction: (CBLStatus(^)())block {
    [_storage inTransaction: block];
}


/** Posts a local NSNotification of a new revision of a document. */
- (void) notifyChange: (CBLDatabaseChange*)change {
    LogTo(CBLDatabase, @"Added: %@", change.addedRevision);
    if (!_changesToNotify)
        _changesToNotify = [[NSMutableArray alloc] init];
    [_changesToNotify addObject: change];
    [self postChangeNotifications];
}

/** Posts a local NSNotification of multiple new revisions. */
- (void) notifyChanges: (NSArray*)changes {
    if (!_changesToNotify)
        _changesToNotify = [[NSMutableArray alloc] init];
    [_changesToNotify addObjectsFromArray: changes];
    [self postChangeNotifications];
}


- (void) postChangeNotifications {
    // This is a 'while' instead of an 'if' because when we finish posting notifications, there
    // might be new ones that have arrived as a result of notification handlers making document
    // changes of their own (the replicator manager will do this.) So we need to check again.
    while (!_storage.inTransaction && _isOpen && !_postingChangeNotifications
            && _changesToNotify.count > 0)
    {
        _postingChangeNotifications = true; // Disallow re-entrant calls
        NSArray* changes = _changesToNotify;
        _changesToNotify = nil;

        if (WillLogTo(CBLDatabase)) {
            NSMutableString* seqs = [NSMutableString string];
            for (CBLDatabaseChange* change in changes) {
                if (seqs.length > 0)
                    [seqs appendString: @", "];
                SequenceNumber seq = [_storage getRevisionSequence: change.addedRevision];
                if (change.echoed)
                    [seqs appendFormat: @"(%lld)", seq];
                else
                    [seqs appendFormat: @"%lld", seq];
            }
            LogTo(CBLDatabase, @"%@: Posting change notifications: seq %@", self, seqs);
        }
        
        [self postPublicChangeNotification: changes];
        [[NSNotificationCenter defaultCenter] postNotificationName: CBL_DatabaseChangesNotification
                                                            object: self
                                                          userInfo: $dict({@"changes", changes})];

        _postingChangeNotifications = false;
    }
}


- (void) dbChanged: (NSNotification*)n {
    CBLDatabase* senderDB = n.object;
    // Was this posted by a _different_ CBLDatabase instance on the same database as me?
    if (senderDB != self && [senderDB.dir isEqualToString: _dir]) {
        // Careful: I am being called on senderDB's thread, not my own!
        if ([[n name] isEqualToString: CBL_DatabaseChangesNotification]) {
            NSMutableArray* echoedChanges = $marray();
            for (CBLDatabaseChange* change in (n.userInfo)[@"changes"]) {
                if (!change.echoed)
                    [echoedChanges addObject: change.copy]; // copied change is marked as echoed
            }
            if (echoedChanges.count > 0) {
                LogTo(CBLDatabase, @"%@: Notified of %u changes by %@",
                      self, (unsigned)echoedChanges.count, senderDB);
                [self doAsync: ^{
                    [self notifyChanges: echoedChanges];
                }];
            }
        } else if ([[n name] isEqualToString: CBL_DatabaseWillBeDeletedNotification]) {
            [self doAsync: ^{
                LogTo(CBLDatabase, @"%@: Notified of deletion; closing", self);
                [self _close];
            }];
        }
    }
}


#pragma mark - GETTING DOCUMENTS:


- (CBL_Revision*) getDocumentWithID: (NSString*)docID
                         revisionID: (NSString*)inRevID
                            options: (CBLContentOptions)options
                             status: (CBLStatus*)outStatus
{
    CBL_MutableRevision* rev = [_storage getDocumentWithID: docID revisionID: inRevID
                                            options: options status: outStatus];
    if (rev && (options & kCBLIncludeAttachments))
        [self expandAttachmentsIn: rev options: options];
    return rev;
}


- (CBL_Revision*) getDocumentWithID: (NSString*)docID
                         revisionID: (NSString*)revID
{
    CBLStatus status;
    return [self getDocumentWithID: docID revisionID: revID options: 0 status: &status];
}


- (BOOL) existsDocumentWithID: (NSString*)docID revisionID: (NSString*)revID {
    CBLStatus status;
    return [self getDocumentWithID: docID revisionID: revID options: kCBLNoBody status: &status] != nil;
}


- (CBLStatus) loadRevisionBody: (CBL_MutableRevision*)rev
                       options: (CBLContentOptions)options
{
    // First check for no-op -- if we just need the default properties and already have them:
    if (options==0 && rev.sequenceIfKnown) {
        NSDictionary* props = rev.properties;
        if (props.cbl_rev && props.cbl_id)
            return kCBLStatusOK;
    }
    Assert(rev.docID && rev.revID);

    CBLStatus status = [_storage loadRevisionBody: rev options: options];

    if (status == kCBLStatusOK)
        if (options & kCBLIncludeAttachments)
            [self expandAttachmentsIn: rev options: options];
    return status;
}

- (CBL_Revision*) revisionByLoadingBody: (CBL_Revision*)rev
                                options: (CBLContentOptions)options
                                 status: (CBLStatus*)outStatus
{
    // First check for no-op -- if we just need the default properties and already have them:
    if (options==0 && rev.sequenceIfKnown) {
        NSDictionary* props = rev.properties;
        if (props.cbl_rev && props.cbl_id)
            return rev;
    }
    CBL_MutableRevision* nuRev = rev.mutableCopy;
    CBLStatus status = [self loadRevisionBody: nuRev options: options];
    if (outStatus)
        *outStatus = status;
    if (CBLStatusIsError(status))
        nuRev = nil;
    return nuRev;
}


- (CBL_RevisionList*) changesSinceSequence: (SequenceNumber)lastSequence
                                   options: (const CBLChangesOptions*)options
                                    filter: (CBLFilterBlock)filter
                                    params: (NSDictionary*)filterParams
                                    status: (CBLStatus*)outStatus
{
    CBL_RevisionFilter revFilter = nil;
    if (filter) {
        revFilter = ^BOOL(CBL_Revision* rev) {
            return [self runFilter: filter params: filterParams onRevision: rev];
        };
    }
    return [_storage changesSinceSequence: lastSequence options: options
                                   filter: revFilter status: outStatus];
}

#pragma mark - FILTERS:


- (BOOL) runFilter: (CBLFilterBlock)filter
            params: (NSDictionary*)filterParams
        onRevision: (CBL_Revision*)rev
{
    if (!filter)
        return YES;
    CBLSavedRevision* publicRev = [[CBLSavedRevision alloc] initWithDatabase: self revision: rev];
    @try {
        return filter(publicRev, filterParams);
    } @catch (NSException* x) {
        MYReportException(x, @"filter block");
        return NO;
    }
}


- (id) getDesignDocFunction: (NSString*)fnName
                        key: (NSString*)key
                   language: (NSString**)outLanguage
{
    NSArray* path = [fnName componentsSeparatedByString: @"/"];
    if (path.count != 2)
        return nil;
    CBL_Revision* rev = [self getDocumentWithID: [@"_design/" stringByAppendingString: path[0]]
                                    revisionID: nil];
    if (!rev)
        return nil;
    *outLanguage = rev[@"language"] ?: @"javascript";
    NSDictionary* container = $castIf(NSDictionary, rev[key]);
    return container[path[1]];
}


- (CBLFilterBlock) compileFilterNamed: (NSString*)filterName status: (CBLStatus*)outStatus {
    CBLFilterBlock filter = [self filterNamed: filterName];
    if (filter)
        return filter;
    id<CBLFilterCompiler> compiler = [CBLDatabase filterCompiler];
    if (!compiler) {
        *outStatus = kCBLStatusNotFound;
        return nil;
    }
    NSString* language;
    NSString* source = $castIf(NSString, [self getDesignDocFunction: filterName
                                                                key: @"filters"
                                                           language: &language]);
    if (!source) {
        *outStatus = kCBLStatusNotFound;
        return nil;
    }

    filter = [compiler compileFilterFunction: source language: language];
    if (!filter) {
        Warn(@"Filter %@ failed to compile", filterName);
        *outStatus = kCBLStatusCallbackError;
        return nil;
    }
    [self setFilterNamed: filterName asBlock: filter];
    return filter;
}


#pragma mark - VIEWS:
// Note: Public view methods like -viewNamed: are in CBLDatabase.m.


- (NSArray*) allViews {
    NSArray* filenames = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: _dir
                                                                             error: NULL];
    return [filenames my_map: ^id(NSString* filename) {
        NSString* viewName = [CBLView fileNameToViewName: filename];
        if (!viewName)
            return nil;
        return [self existingViewNamed: viewName];
    }];
}


- (void) forgetViewNamed: (NSString*)name {
    [_views removeObjectForKey: name];
}


- (CBLView*) makeAnonymousView {
    for (;;) {
        NSString* name = $sprintf(@"$anon$%lx", random());
        if (![self existingViewNamed: name])
            return [self viewNamed: name];
    }
}

- (CBLView*) compileViewNamed: (NSString*)viewName status: (CBLStatus*)outStatus {
    CBLView* view = [self existingViewNamed: viewName];
    if (view && view.mapBlock)
        return view;
    
    // No CouchbaseLite view is defined, or it hasn't had a map block assigned;
    // see if there's a CouchDB view definition we can compile:
    NSString* language;
    NSDictionary* viewProps = $castIf(NSDictionary, [self getDesignDocFunction: viewName
                                                                           key: @"views"
                                                                      language: &language]);
    if (!viewProps) {
        *outStatus = kCBLStatusNotFound;
        return nil;
    } else if (![CBLView compiler]) {
        *outStatus = kCBLStatusNotImplemented;
        return nil;
    }
    view = [self viewNamed: viewName];
    if (![view compileFromProperties: viewProps language: language]) {
        *outStatus = kCBLStatusCallbackError;
        return nil;
    }
    return view;
}


- (CBLQueryIteratorBlock) getAllDocs: (CBLQueryOptions*)options
                              status: (CBLStatus*)outStatus
{
    return [_storage getAllDocs: options status: outStatus];
}


- (void) postNotification: (NSNotification*)notification {
    [self doAsync:^{
        [[NSNotificationCenter defaultCenter] postNotification: notification];
    }];
}


    - (BOOL) createLocalCheckpointDocument: (NSError**)outError {
    NSDictionary* document = @{ kCBLDatabaseLocalCheckpoint_LocalUUID : self.privateUUID };
    BOOL result = [self putLocalDocument: document withID: kLocalCheckpointDocId error: outError];
    if (!result)
        Warn(@"CBLDatabase: Could not create a local checkpoint document with an error: %@", *outError);
    return result;
}

- (NSDictionary*) getLocalCheckpointDocument {
    return [self existingLocalDocumentWithID:kLocalCheckpointDocId];
}


@end
