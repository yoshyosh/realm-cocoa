////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

#import "RLMChangeListener.h"

#import "RLMRealm_Private.hpp"

#include <tightdb/group_shared.hpp>
#include <tightdb/commit_log.hpp>
#include <tightdb/lang_bind_helper.hpp>

// A weak holder for an RLMRealm to allow calling performSelector:onThread: without
// a strong reference to the realm
@interface RLMWeakNotifier : NSObject
@end

@implementation RLMWeakNotifier {
    __weak RLMRealm *_realm;
    // flag used to avoid queuing up redundant notifications
    std::atomic_flag _hasPendingNotification;
}

- (instancetype)initWithRealm:(RLMRealm *)realm
{
    self = [super init];
    if (self) {
        _realm = realm;
        _hasPendingNotification.clear();
    }
    return self;
}

- (void)notify
{
    _hasPendingNotification.clear();
    [_realm handleExternalCommit];
}

- (void)notifyOnTargetThread
{
    RLMRealm *realm = _realm;
    if (realm && !_hasPendingNotification.test_and_set()) {
        [self performSelector:@selector(notify)
                     onThread:realm->_thread withObject:nil waitUntilDone:NO];
    }
}
@end

@implementation RLMChangeListener {
    NSMutableDictionary *_cache;
    std::unique_ptr<Replication> _replication;
    std::unique_ptr<SharedGroup> _sharedGroup;
    NSString *_path;
    NSMutableArray *_realms;
    NSCondition *_shutdownCondition;
}

- (instancetype)initWithPath:(NSString *)path inMemory:(BOOL)inMemory cache:(NSMutableDictionary *)cache {
    self = [super initWithTarget:self selector:@selector(run) object:nil];
    if (self) {
        _cache = cache;
        _replication.reset(tightdb::makeWriteLogCollector(path.UTF8String));
        SharedGroup::DurabilityLevel durability = inMemory ? SharedGroup::durability_MemOnly :
                                                             SharedGroup::durability_Full;
        _sharedGroup = std::make_unique<SharedGroup>(*_replication, durability);
        _sharedGroup->begin_read();

        _path = path;
        _realms = [NSMutableArray array];
        _shutdownCondition = [[NSCondition alloc] init];
        [self start];
    }
    return self;
}

- (void)addRealm:(RLMRealm *)realm {
    @synchronized (_realms) {
        [_realms addObject:[[RLMWeakNotifier alloc] initWithRealm:realm]];
    }
}

- (void)removeRealm:(RLMRealm *)realm {
    @synchronized (_realms) {
        @autoreleasepool {
            // The NSPredicate needs to be deallocated before we return or it crashes,
            // since we're called from -dealloc and so retaining `realm` doesn't work.
            [_realms filterUsingPredicate:[NSPredicate predicateWithFormat:@"realm != nil AND realm != %@", realm]];
        }

        if (_realms.count == 0) {
            [_cache removeObjectForKey:_path];
        }
        else {
            return;
        }
    }

    // we can be called from within `run` if the notifier's brief strong
    // reference manages to be the last strong reference to the realm, which
    // means that _shutdownCondition is already locked and we don't need
    // to wait for ourself to shut down
    if ([NSThread currentThread] == self) {
        _sharedGroup.reset();
        _replication.reset();
    }
    else {
        [_shutdownCondition lock];
        if (_sharedGroup) {
            _sharedGroup->wait_for_change_release();
        }
        // wait for the thread to wake up and tear down the SharedGroup to
        // ensure that it doesn't continue to care about the files on disk after
        // the last RLMRealm instance for them is deallocated
        while (_sharedGroup) {
            [_shutdownCondition wait];
        }
        [_shutdownCondition unlock];
    }
}

- (void)run {
    while (_sharedGroup && _sharedGroup->wait_for_change()) {
        // we don't have any accessors, so just start a new read transaction
        // rather than using advance_read() as that does far more work
        _sharedGroup->end_read();
        _sharedGroup->begin_read();

        @synchronized (_realms) {
            for (RLMWeakNotifier *notifier in _realms) {
                [notifier notifyOnTargetThread];
            }
        }
    }

    [_shutdownCondition lock];
    _sharedGroup.reset();
    _replication.reset();
    [_shutdownCondition signal];
    [_shutdownCondition unlock];
}
@end
