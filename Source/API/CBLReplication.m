//
//  CBLReplication.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 6/22/12.
//  Copyright (c) 2012-2013 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLReplication.h"
#import "CouchbaseLitePrivate.h"

#import "CBL_Pusher.h"
#import "CBLDatabase+Replication.h"
#import "CBLDatabase+Internal.h"
#import "CBLManager+Internal.h"
#import "CBL_Server.h"
#import "CBLPersonaAuthorizer.h"
#import "CBLFacebookAuthorizer.h"
#import "MYBlockUtils.h"
#import "MYURLUtils.h"


#define RUN_IN_BACKGROUND 1


NSString* const kCBLReplicationChangeNotification = @"CBLReplicationChange";


#define kByChannelFilterName @"sync_gateway/bychannel"
#define kChannelsQueryParam  @"channels"


@interface CBLReplication ()
@property (nonatomic, readwrite) bool running;
@property (nonatomic, readwrite) CBLReplicationMode mode;
@property (nonatomic, readwrite) unsigned completed, total;
@property (nonatomic, readwrite, retain) NSError* error;
@end


@implementation CBLReplication
{
    bool _started;
    CBL_Replicator* _bg_replicator;       // ONLY used on the server thread
}


@synthesize localDatabase=_database, create_target=_create_target;
@synthesize continuous=_continuous, filter=_filter, query_params=_query_params;
@synthesize doc_ids=_doc_ids, network=_network, remoteURL=_remoteURL, pull=_pull;
@synthesize headers=_headers, OAuth=_OAuth, facebookEmailAddress=_facebookEmailAddress;
@synthesize personaEmailAddress=_personaEmailAddress, customProperties=_customProperties;
@synthesize running = _running, completed=_completed, total=_total, error = _error, mode=_mode;


- (instancetype) initPullFromSourceURL: (NSURL*)source toDatabase: (CBLDatabase*)database {
    return [self initWithDatabase: database remote: source pull: YES];
}

- (instancetype) initPushFromDatabase: (CBLDatabase*)database toTargetURL: (NSURL*)target {
    return [self initWithDatabase: database remote: target pull: NO];
}

- (instancetype) initWithDatabase: (CBLDatabase*)database
                           remote: (NSURL*)remote
                             pull: (BOOL)pull
{
    NSParameterAssert(database);
    NSParameterAssert(remote);
    self = [super init];
    if (self) {
        _database = database;
        _remoteURL = remote;
        _pull = pull;
    }
    return self;
}


- (void) dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver: self];
}


- (void) deleteReplication {
    [self stop];
    [_database.manager forgetReplication: self];
}


- (NSString*) description {
    return [NSString stringWithFormat: @"%@[%@ %@]",
                self.class, (self.pull ? @"from" : @"to"), self.remoteURL.my_sanitizedString];
}

- (void) setContinuous:(bool)continuous {
    if (continuous != _continuous) {
        _continuous = continuous;
        [self restart];
    }
}

- (void) setFilter:(NSString *)filter {
    if (!$equal(filter, _filter)) {
        _filter = filter;
        [self restart];
    }
}

- (void) setHeaders: (NSDictionary*)headers {
    if (!$equal(headers, _headers)) {
        _headers = headers;
        [self restart];
    }
}


- (NSArray*) channels {
    NSString* params = self.query_params[kChannelsQueryParam];
    if (!self.pull || !$equal(self.filter, kByChannelFilterName) || params.length == 0)
        return nil;
    return [params componentsSeparatedByString: @","];
}

- (void) setChannels:(NSArray *)channels {
    if (channels) {
        Assert(self.pull, @"filterChannels can only be set in pull replications");
        self.filter = kByChannelFilterName;
        self.query_params = @{kChannelsQueryParam: [channels componentsJoinedByString: @","]};
    } else if ($equal(self.filter, kByChannelFilterName)) {
        self.filter = nil;
        self.query_params = nil;
    }
}


#pragma mark - AUTHENTICATION:


- (NSURLCredential*) credential {
    return [self.remoteURL my_credentialForRealm: nil
                            authenticationMethod: NSURLAuthenticationMethodDefault];
}

- (void) setCredential:(NSURLCredential *)cred {
    // Hardcoded username doesn't mix with stored credentials.
    NSURL* url = self.remoteURL;
    _remoteURL = url.my_URLByRemovingUser;

    NSURLProtectionSpace* space = [url my_protectionSpaceWithRealm: nil
                                            authenticationMethod: NSURLAuthenticationMethodDefault];
    NSURLCredentialStorage* storage = [NSURLCredentialStorage sharedCredentialStorage];
    if (cred) {
        [storage setDefaultCredential: cred forProtectionSpace: space];
    } else {
        cred = [storage defaultCredentialForProtectionSpace: space];
        if (cred)
            [storage removeCredential: cred forProtectionSpace: space];
    }
    [self restart];
}


- (bool) registerFacebookToken: (NSString*)token forEmailAddress: (NSString*)email {
    if (![CBLFacebookAuthorizer registerToken: token forEmailAddress: email forSite: self.remoteURL])
        return false;
    self.facebookEmailAddress = email;
    [self restart];
    return true;
}


- (NSURL*) personaOrigin {
    return self.remoteURL.my_baseURL;
}

- (bool) registerPersonaAssertion: (NSString*)assertion {
    NSString* email = [CBLPersonaAuthorizer registerAssertion: assertion];
    if (!email) {
        Warn(@"Invalid Persona assertion: %@", assertion);
        return false;
    }
    self.personaEmailAddress = email;
    [self restart];
    return true;
}


+ (void) setAnchorCerts: (NSArray*)certs onlyThese: (BOOL)onlyThese {
    [CBL_Replicator setAnchorCerts: certs onlyThese: onlyThese];
}


#pragma mark - START/STOP:


- (NSDictionary*) properties {
    // This is basically the inverse of -[CBLManager parseReplicatorProperties:...]
    NSMutableDictionary* props = $mdict({@"continuous", @(_continuous)},
                                        {@"create_target", @(_create_target)},
                                        {@"filter", _filter},
                                        {@"query_params", _query_params},
                                        {@"doc_ids", _doc_ids});
    NSMutableDictionary* authDict = nil;
    if (_OAuth || _facebookEmailAddress) {
        authDict = $mdict({@"oauth", _OAuth});
        if (_facebookEmailAddress)
            authDict[@"facebook"] = @{@"email": _facebookEmailAddress};
        if (_personaEmailAddress)
            authDict[@"persona"] = @{@"email": _personaEmailAddress};
    }
    NSDictionary* remote = $dict({@"url", _remoteURL.absoluteString},
                                 {@"headers", _headers},
                                 {@"auth", authDict});
    if (_pull) {
        props[@"source"] = remote;
        props[@"target"] = _database.name;
    } else {
        props[@"source"] = _database.name;
        props[@"target"] = remote;
    }

    if (_customProperties)
        [props addEntriesFromDictionary: _customProperties];
    return props;
}


- (void) tellDatabaseManager: (void (^)(CBLManager*))block {
#if RUN_IN_BACKGROUND
    [_database.manager.backgroundServer tellDatabaseManager: block];
#else
    block(_database.manager);
#endif
}


- (void) start {
    if (!_database.isOpen)  // Race condition: db closed before replication starts
        return;

    if (!_started) {
        _started = YES;

        NSDictionary* properties= self.properties;
        [self tellDatabaseManager: ^(CBLManager* bgManager) {
            // This runs on the server thread:
            [self bg_startReplicator: bgManager properties: properties];
        }];
    }
}


- (void) stop {
    [self tellDatabaseManager:^(CBLManager* dbmgr) {
        // This runs on the server thread:
        [self bg_stopReplicator];
    }];
    _started = NO;
}


- (void) restart {
    if (_started) {
        [self stop];
        [self start];
    }
}


- (void) updateMode: (CBLReplicationMode)mode
              error: (NSError*)error
          processed: (NSUInteger)changesProcessed
            ofTotal: (NSUInteger)changesTotal
{
    if (!_started)
        return;
    if (mode == kCBLReplicationStopped)
        _started = NO;
    
    BOOL changed = NO;
    if (mode != _mode) {
        self.mode = mode;
        changed = YES;
    }
    BOOL running = (mode > kCBLReplicationStopped);
    if (running != _running) {
        self.running = running;
        changed = YES;
    }
    if (!$equal(error, _error)) {
        self.error = error;
        changed = YES;
    }
    if (changesProcessed != _completed) {
        self.completed = changesProcessed;
        changed = YES;
    }
    if (changesTotal != _total) {
        self.total = changesTotal;
        changed = YES;
    }
    if (changed) {
        LogTo(CBLReplication, @"%@: mode=%d, completed=%u, total=%u (changed=%d)",
              self, mode, (unsigned)changesProcessed, (unsigned)changesTotal, changed);
        [[NSNotificationCenter defaultCenter]
                        postNotificationName: kCBLReplicationChangeNotification object: self];
    }
}


#pragma mark - BACKGROUND OPERATIONS:


// CAREFUL: This is called on the server's background thread!
- (void) bg_setReplicator: (CBL_Replicator*)repl {
    if (_bg_replicator) {
        [[NSNotificationCenter defaultCenter] removeObserver: self name: nil
                                                      object: _bg_replicator];
    }
    _bg_replicator = repl;
    if (_bg_replicator) {
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(bg_replicationProgressChanged:)
                                                     name: CBL_ReplicatorProgressChangedNotification
                                                   object: _bg_replicator];
    }
}


// CAREFUL: This is called on the server's background thread!
- (void) bg_startReplicator: (CBLManager*)server_dbmgr
                 properties: (NSDictionary*)properties
{
    // The setup should use properties, not ivars, because the ivars may change on the main thread.
    CBLStatus status;
    CBL_Replicator* repl = [server_dbmgr replicatorWithProperties: properties status: &status];
    if (!repl) {
        [_database doAsync: ^{
            [self updateMode: kCBLReplicationStopped
                       error: CBLStatusToNSError(status, nil)
                   processed: 0 ofTotal: 0];
        }];
        return;
    }
    [self bg_setReplicator: repl];
    [repl start];
    [self bg_updateProgress];
}


// CAREFUL: This is called on the server's background thread!
- (void) bg_stopReplicator {
    [_bg_replicator stop];
}


// CAREFUL: This is called on the server's background thread!
- (void) bg_replicationProgressChanged: (NSNotification*)n
{
    AssertEq(n.object, _bg_replicator);
    [self bg_updateProgress];
}


// CAREFUL: This is called on the server's background thread!
- (void) bg_updateProgress {
    CBLReplicationMode mode;
    if (!_bg_replicator.running)
        mode = kCBLReplicationStopped;
    else if (!_bg_replicator.online)
        mode = kCBLReplicationOffline;
    else
        mode = _bg_replicator.active ? kCBLReplicationActive : kCBLReplicationIdle;
    
    // Communicate its state back to the main thread:
    NSError* error = _bg_replicator.error;
    NSUInteger changes = _bg_replicator.changesProcessed;
    NSUInteger total = _bg_replicator.changesTotal;
    [_database doAsync: ^{
        [self updateMode: mode error: error processed: changes ofTotal: total];
    }];
    
    if (mode == kCBLReplicationStopped) {
        [self bg_setReplicator: nil];
    }
}


@end
