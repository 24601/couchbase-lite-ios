//
//  CBLDatabase+Replication.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/27/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLDatabase+Replication.h"
#import "CBLInternal.h"
#import "CBL_Puller.h"
#import "MYBlockUtils.h"

#import <CBForest/CBForest.h>
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"


#define kActiveReplicatorCleanupDelay 10.0


@implementation CBLDatabase (Replication)


- (NSArray*) activeReplicators {
    return _activeReplicators;
}

- (void) addActiveReplicator: (CBL_Replicator*)repl {
    if (!_activeReplicators) {
        _activeReplicators = [[NSMutableArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(replicatorDidStop:)
                                                     name: CBL_ReplicatorStoppedNotification
                                                   object: nil];
    }
    if (![_activeReplicators containsObject: repl])
        [_activeReplicators addObject: repl];
}


- (CBL_Replicator*) activeReplicatorLike: (CBL_Replicator*)repl {
    for (CBL_Replicator* activeRepl in _activeReplicators) {
        if ([activeRepl hasSameSettingsAs: repl])
            return activeRepl;
    }
    return nil;
}


- (void) stopAndForgetReplicator: (CBL_Replicator*)repl {
    [repl databaseClosing];
    [_activeReplicators removeObjectIdenticalTo: repl];
}


- (void) replicatorDidStop: (NSNotification*)n {
    CBL_Replicator* repl = n.object;
    if (repl.error)     // Leave it around a while so clients can see the error
        MYAfterDelay(kActiveReplicatorCleanupDelay,
                     ^{[_activeReplicators removeObjectIdenticalTo: repl];});
    else
        [_activeReplicators removeObjectIdenticalTo: repl];
}


- (NSString*) lastSequenceWithCheckpointID: (NSString*)checkpointID {
    // This table schema is out of date but I'm keeping it the way it is for compatibility.
    // The 'remote' column now stores the opaque checkpoint IDs, and 'push' is ignored.
    return [_fmdb stringForQuery:@"SELECT last_sequence FROM replicators WHERE remote=?",
                                 checkpointID];
}

- (BOOL) setLastSequence: (NSString*)lastSequence withCheckpointID: (NSString*)checkpointID {
    return [_fmdb executeUpdate: 
            @"INSERT OR REPLACE INTO replicators (remote, push, last_sequence) VALUES (?, -1, ?)",
            checkpointID, lastSequence];
}


+ (NSString*) joinQuotedStrings: (NSArray*)strings {
    if (strings.count == 0)
        return @"";
    NSMutableString* result = [NSMutableString stringWithString: @"'"];
    BOOL first = YES;
    for (NSString* str in strings) {
        if (first)
            first = NO;
        else
            [result appendString: @"','"];
        NSRange range = NSMakeRange(result.length, str.length);
        [result appendString: str];
        [result replaceOccurrencesOfString: @"'" withString: @"''"
                                   options: NSLiteralSearch range: range];
    }
    [result appendString: @"'"];
    return result;
}


- (BOOL) findMissingRevisions: (CBL_RevisionList*)revs {
    [revs sortByDocID];
    CBForestVersions* doc = nil;
    for (NSInteger i = revs.count-1; i >= 0; i--) {
        CBL_Revision* rev = revs[i];
        if (!$equal(rev.docID, doc.docID))
            doc = (CBForestVersions*)[_forest documentWithID: rev.docID options: 0 error: NULL];
        if (doc && [doc flagsOfRevision: rev.revID] != 0)
            [revs removeRev: rev];
    }
    return YES;
}


@end
