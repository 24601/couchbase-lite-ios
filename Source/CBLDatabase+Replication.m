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

extern "C" {
#import "CBLDatabase+Replication.h"
#import "CBLDatabase+LocalDocs.h"
#import "CBLInternal.h"
#import "CBL_Puller.h"
#import "MYBlockUtils.h"
}
#import <CBForest/CBForest.hh>
using namespace forestdb;


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


static NSString* checkpointInfoKey(NSString* checkpointID) {
    return [@"checkpoint/" stringByAppendingString: checkpointID];
}


- (NSString*) lastSequenceWithCheckpointID: (NSString*)checkpointID {
    // This table schema is out of date but I'm keeping it the way it is for compatibility.
    // The 'remote' column now stores the opaque checkpoint IDs, and 'push' is ignored.
    return [self infoForKey: checkpointInfoKey(checkpointID)];
}

- (BOOL) setLastSequence: (NSString*)lastSequence withCheckpointID: (NSString*)checkpointID {
    return [self setInfo: lastSequence forKey: checkpointInfoKey(checkpointID)] == kCBLStatusOK;
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


- (BOOL) findMissingRevisions: (CBL_RevisionList*)revs
                       status: (CBLStatus*)outStatus
{
    [revs sortByDocID];
    __block VersionedDocument* doc = NULL;
    *outStatus = [self _try: ^CBLStatus {
        NSString* lastDocID = nil;
        for (NSInteger i = revs.count-1; i >= 0; i--) {
            CBL_Revision* rev = revs[i];
            if (!$equal(rev.docID, lastDocID)) {
                lastDocID = rev.docID;
                delete doc;
                doc = new VersionedDocument(*_forest, lastDocID);
            }
            if (doc && doc->get(rev.revID) != NULL)
                [revs removeRev: rev];
        }
        return kCBLStatusOK;
    }];
    delete doc;
    return !CBLStatusIsError(*outStatus);
}


@end
