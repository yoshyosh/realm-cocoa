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

#import <tightdb/group_shared.hpp>
#import <tightdb/commit_log.hpp>
#import <tightdb/lang_bind_helper.hpp>

@interface RLMChangeListener : NSObject
- (instancetype)initWithPath:(NSString *)path
                    inMemory:(BOOL)inMemory;

- (void)addRealm:(RLMRealm *)realm;
- (bool)removeRealm:(RLMRealm *)realm;
- (void)stop;
@end

static NSMutableDictionary *s_listenersPerPath = [NSMutableDictionary new];

void RLMStartListeningForChanges(RLMRealm *realm) {
    @synchronized (s_listenersPerPath) {
        RLMChangeListener *listener = s_listenersPerPath[realm.path];
        if (!listener) {
            listener = [[RLMChangeListener alloc] initWithPath:realm.path inMemory:realm->_inMemory];
            s_listenersPerPath[realm.path] = listener;
        }
        [listener addRealm:realm];
    }
}

void RLMStopListeningForChanges(RLMRealm *realm) {
    @synchronized (s_listenersPerPath) {
        RLMChangeListener *listener = s_listenersPerPath[realm.path];
        if ([listener removeRealm:realm]) {
            [s_listenersPerPath removeObjectForKey:realm.path];
            [listener stop];
        }
    }
}

void RLMClearListeners() {
    @synchronized (s_listenersPerPath) {
        [s_listenersPerPath removeAllObjects];
    }
}

// A weak holder for an RLMRealm to allow calling performSelector:onThread:
// without a strong reference to the realm
@interface RLMWeakNotifier : NSObject
@end

@implementation RLMWeakNotifier {
    __weak RLMRealm *_realm;
    NSThread *_thread;
    // flag used to avoid queuing up redundant notifications
    std::atomic_flag _hasPendingNotification;
}

- (instancetype)initWithRealm:(RLMRealm *)realm
{
    self = [super init];
    if (self) {
        _realm = realm;
        _thread = [NSThread currentThread];
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
    if (!_hasPendingNotification.test_and_set()) {
        [self performSelector:@selector(notify)
                     onThread:_thread withObject:nil waitUntilDone:NO];
    }
}
@end

@implementation RLMChangeListener {
    SharedGroup::DurabilityLevel _durability;
    std::unique_ptr<Replication> _replication;
    std::unique_ptr<SharedGroup> _sharedGroup;

    dispatch_queue_t _guardQueue;
    dispatch_queue_t _waitQueue;
    NSMutableArray *_realms;
    bool _cancel;
}

- (instancetype)initWithPath:(NSString *)path inMemory:(BOOL)inMemory {
    self = [super init];
    if (self) {
        _replication.reset(tightdb::makeWriteLogCollector(path.UTF8String));
        _durability = inMemory ? SharedGroup::durability_MemOnly : SharedGroup::durability_Full;
        _realms = [NSMutableArray array];
        _guardQueue = dispatch_queue_create("Realm change listener guard queue", DISPATCH_QUEUE_SERIAL);
        _waitQueue = dispatch_queue_create("Realm change listener wait_for_change queue", DISPATCH_QUEUE_SERIAL);
        [self start];
    }
    return self;
}

- (void)addRealm:(RLMRealm *)realm {
    dispatch_sync(_guardQueue, ^{
        [_realms addObject:[[RLMWeakNotifier alloc] initWithRealm:realm]];
    });
}

- (bool)removeRealm:(RLMRealm *)realm {
    __block bool empty;
    dispatch_sync(_guardQueue, ^{
        @autoreleasepool {
            // The NSPredicate needs to be deallocated before we return or it crashes,
            // since we're called from -dealloc and so retaining `realm` doesn't work.
            [_realms filterUsingPredicate:[NSPredicate predicateWithFormat:@"realm != nil AND realm != %@", realm]];
        }
        empty = _realms.count == 0;
    });
    return empty;
}

- (void)start {
    // Create the SharedGroup on a different thread as it's kinda slow
    dispatch_async(_guardQueue, ^{
        _sharedGroup = std::make_unique<SharedGroup>(*_replication, _durability);
        _sharedGroup->begin_read();
    });

    dispatch_async(_waitQueue, ^{
        // wait for _sharedGroup to be initialized
        dispatch_sync(_guardQueue, ^{ });

        while (!_cancel && _sharedGroup->wait_for_change() && !_cancel) {
            // we don't have any accessors, so just start a new read transaction
            // rather than using advance_read() as that does far more work
            _sharedGroup->end_read();
            _sharedGroup->begin_read();

            dispatch_async(_guardQueue, ^{
                for (RLMWeakNotifier *notifier in _realms) {
                    [notifier notifyOnTargetThread];
                }
            });
        }
    });
}

- (void)stop {
    dispatch_sync(_guardQueue, ^{
        _cancel = true;
        _sharedGroup->wait_for_change_release();

        // wait for the thread to wake up and tear down the SharedGroup to
        // ensure that it doesn't continue to care about the files on disk after
        // the last RLMRealm instance for them is deallocated
        dispatch_sync(_waitQueue, ^{});
    });
}

@end
